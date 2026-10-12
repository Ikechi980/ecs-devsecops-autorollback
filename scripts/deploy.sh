#!/usr/bin/env bash
# Release NEW_IMAGE (repo@sha256:...) to an ECS service and report whether the
# rollout really succeeded.
#
# Success is judged ONLY from the service's PRIMARY deployment:
#   - PRIMARY still runs our task definition and rolloutState == COMPLETED
# Failure:
#   - PRIMARY switched to another task definition (circuit breaker / alarm
#     rollback restored the previous one), rolloutState == FAILED, or timeout.
#
# Deliberately NOT `aws ecs wait services-stable`: after a circuit-breaker
# rollback the service is stable again -- on the OLD version -- so that waiter
# reports a failed release as a success.
#
# Required env: CLUSTER SERVICE NEW_IMAGE SSM_IMAGE_CURRENT SSM_IMAGE_LKG ROLLBACK_ALARMS
# Optional env: DEPLOY_TIMEOUT_SECONDS (default 1200), POLL_SECONDS (default 15)

set -euo pipefail

: "${DEPLOY_TIMEOUT_SECONDS:=1200}"
: "${POLL_SECONDS:=15}"
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-5}"
export AWS_PAGER=""

CONTAINER_NAME="app"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "missing required env var ${name}"
  done
}

require_env CLUSTER SERVICE NEW_IMAGE SSM_IMAGE_CURRENT SSM_IMAGE_LKG ROLLBACK_ALARMS

# Only immutable digest references are deployable; tags can be repointed.
if [[ ! "${NEW_IMAGE}" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
  die "NEW_IMAGE must be an immutable digest reference (repo@sha256:<64 hex>), got: ${NEW_IMAGE}"
fi

# Fields RegisterTaskDefinition accepts. Allowlisted (not "delete read-only
# fields") so a new read-only field from DescribeTaskDefinition can't break us.
REGISTER_FIELDS='["family","taskRoleArn","executionRoleArn","networkMode",
  "containerDefinitions","volumes","placementConstraints","requiresCompatibilities",
  "cpu","memory","pidMode","ipcMode","proxyConfiguration","inferenceAccelerators",
  "ephemeralStorage","runtimePlatform","enableFaultInjection"]'

describe_service() {
  aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
    --query 'services[0]' --output json
}

ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text
}

ssm_put() {
  aws ssm put-parameter --name "$1" --value "$2" \
    --type SecureString --overwrite >/dev/null
}

# ---------- 1. Record what is running now ----------

PREV_TASK_DEF="$(describe_service | jq -r '.taskDefinition')"
[[ "${PREV_TASK_DEF}" == arn:* ]] || die "could not read the service's current task definition"
PREV_IMAGE="$(ssm_get "${SSM_IMAGE_CURRENT}")"

log "service:           ${CLUSTER}/${SERVICE}"
log "running task def:  ${PREV_TASK_DEF}"
log "current image:     ${PREV_IMAGE}"
log "new image:         ${NEW_IMAGE}"

# What is running now becomes the last known good before we touch anything.
ssm_put "${SSM_IMAGE_LKG}" "${PREV_IMAGE}"
log "last-known-good <- ${PREV_IMAGE}"

# ---------- 2. Clone the running task definition with the new image ----------

NEW_TASK_DEF_JSON="$(
  aws ecs describe-task-definition --task-definition "${PREV_TASK_DEF}" \
    --query 'taskDefinition' --output json |
    jq --arg image "${NEW_IMAGE}" --arg name "${CONTAINER_NAME}" \
       --argjson fields "${REGISTER_FIELDS}" '
      if ([.containerDefinitions[].name] | index($name)) == null
      then error("task definition has no container named \($name)")
      else . end
      | with_entries(select(.key as $k | $fields | index($k)))
      # Set the image and DROP `command`: otherwise the bootstrap command
      # carries over and the real image never runs its own CMD.
      | .containerDefinitions |= map(
          if .name == $name then (.image = $image | del(.command)) else . end)
    '
)"

NEW_TASK_DEF="$(
  aws ecs register-task-definition --cli-input-json "${NEW_TASK_DEF_JSON}" \
    --query 'taskDefinition.taskDefinitionArn' --output text
)"
[[ "${NEW_TASK_DEF}" == arn:* ]] || die "register-task-definition did not return an ARN"
log "registered:        ${NEW_TASK_DEF}"

# ---------- 3. Point SSM at the new image and roll out ----------

ssm_put "${SSM_IMAGE_CURRENT}" "${NEW_IMAGE}"
log "current <- ${NEW_IMAGE}"

aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
  --task-definition "${NEW_TASK_DEF}" >/dev/null
log "update-service issued; watching the PRIMARY deployment"

# ---------- 4. Watch the PRIMARY deployment ----------

deadline=$((SECONDS + DEPLOY_TIMEOUT_SECONDS))
last_status=""

while :; do
  svc_json="$(describe_service)"
  primary="$(jq -c '[.deployments[] | select(.status == "PRIMARY")][0]' <<<"${svc_json}")"
  primary_td="$(jq -r '.taskDefinition' <<<"${primary}")"
  rollout="$(jq -r '.rolloutState // "UNKNOWN"' <<<"${primary}")"
  reason="$(jq -r '.rolloutStateReason // ""' <<<"${primary}")"
  counts="$(jq -r '"running=\(.runningCount) pending=\(.pendingCount) failed=\(.failedTasks)"' <<<"${primary}")"

  status="${rollout} ${counts}"
  if [[ "${status}" != "${last_status}" ]]; then
    log "PRIMARY ${primary_td##*/} ${status}"
    last_status="${status}"
  fi

  if [[ "${primary_td}" != "${NEW_TASK_DEF}" ]]; then
    # The why lives on OUR (now demoted) deployment, not the new PRIMARY.
    ours_reason="$(jq -r --arg td "${NEW_TASK_DEF}" \
      '[.deployments[] | select(.taskDefinition == $td)][0].rolloutStateReason // "n/a"' <<<"${svc_json}")"
    die "ECS rolled back to ${primary_td##*/} (circuit breaker or alarm): ${ours_reason}"
  fi

  case "${rollout}" in
    COMPLETED)
      log "rollout COMPLETED on ${NEW_TASK_DEF##*/}"
      break
      ;;
    FAILED)
      die "rollout FAILED: ${reason}"
      ;;
  esac

  if (( SECONDS >= deadline )); then
    die "timed out after ${DEPLOY_TIMEOUT_SECONDS}s waiting for rollout (last: ${status})"
  fi
  sleep "${POLL_SECONDS}"
done

log "deployed ${NEW_IMAGE}"
