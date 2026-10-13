#!/usr/bin/env bash
# Release NEW_IMAGE (repo@sha256:...) to an ECS service and report whether the
# rollout really succeeded. Rollback layers this script owns:
#
#   3. Bake window: after COMPLETED, watch ROLLBACK_ALARMS for BAKE_MINUTES.
#      ECS only watches alarms *during* a deployment; this covers the period
#      right after it.
#   4. EXIT trap: on ANY failure, put the previous task definition back (unless
#      ECS already did) and reset SSM current to last-known-good.
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
# Optional env: DEPLOY_TIMEOUT_SECONDS (1200) POLL_SECONDS (15)
#               BAKE_MINUTES (10) BAKE_POLL_SECONDS (30) GITHUB_STEP_SUMMARY

set -euo pipefail

: "${DEPLOY_TIMEOUT_SECONDS:=1200}"
: "${POLL_SECONDS:=15}"
: "${BAKE_MINUTES:=10}"
: "${BAKE_POLL_SECONDS:=30}"
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-5}"
export AWS_PAGER=""

CONTAINER_NAME="app"

# Release state, read by the EXIT handler.
PREV_TASK_DEF=""
PREV_IMAGE=""
NEW_TASK_DEF=""
SSM_UPDATED=false
SERVICE_UPDATED=false
FAIL_REASON=""
STAGE="init"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() { FAIL_REASON="$*"; log "ERROR: $*"; exit 1; }

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY}"
  fi
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "missing required env var ${name}"
  done
}

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

# Interruptible sleep: a trapped signal ends `wait` immediately, whereas a
# foreground `sleep` would delay the trap until it finished.
pause() { sleep "$1" & wait "$!"; }

# Poll until the PRIMARY deployment runs task def $1 and is COMPLETED.
# Returns 0 on success; sets WAIT_REASON and returns 1 otherwise. Runs in the
# main shell (never inside $(...)) so cancellation signals are handled at once.
WAIT_REASON=""
wait_for_rollout() {
  local want_td="$1" timeout="$2"
  local deadline=$((SECONDS + timeout)) last="" svc primary primary_td rollout status
  while :; do
    svc="$(describe_service)"
    primary="$(jq -c '[.deployments[] | select(.status == "PRIMARY")][0]' <<<"${svc}")"
    primary_td="$(jq -r '.taskDefinition' <<<"${primary}")"
    rollout="$(jq -r '.rolloutState // "UNKNOWN"' <<<"${primary}")"
    status="${rollout} $(jq -r '"running=\(.runningCount) pending=\(.pendingCount) failed=\(.failedTasks)"' <<<"${primary}")"
    if [[ "${status}" != "${last}" ]]; then
      log "PRIMARY ${primary_td##*/} ${status}"
      last="${status}"
    fi

    if [[ "${primary_td}" != "${want_td}" ]]; then
      # The why lives on OUR (now demoted) deployment, not the new PRIMARY.
      WAIT_REASON="ECS rolled back to ${primary_td##*/} (circuit breaker or alarm): $(jq -r --arg td "${want_td}" \
        '[.deployments[] | select(.taskDefinition == $td)][0].rolloutStateReason // "n/a"' <<<"${svc}")"
      return 1
    fi
    case "${rollout}" in
      COMPLETED) return 0 ;;
      FAILED)
        WAIT_REASON="rollout FAILED: $(jq -r '.rolloutStateReason // ""' <<<"${primary}")"
        return 1
        ;;
    esac
    if ((SECONDS >= deadline)); then
      WAIT_REASON="timed out after ${timeout}s waiting for ${want_td##*/} (last: ${status})"
      return 1
    fi
    pause "${POLL_SECONDS}"
  done
}

# ---------- Layer 4: runs on every exit ----------

on_exit() {
  local rc=$?
  set +e # the handler must run to the end even if one call fails
  trap - EXIT

  if ((rc == 0)); then
    summary "### ✅ Release succeeded" "" \
      "| | |" "|---|---|" \
      "| Image | \`${NEW_IMAGE}\` |" \
      "| Task definition | \`${NEW_TASK_DEF##*/}\` |" \
      "| Bake window | ${BAKE_MINUTES} min, no rollback alarm fired |" \
      "| Last known good | \`${PREV_IMAGE}\` |"
    exit 0
  fi

  local cancelled=false
  if ((rc == 130 || rc == 143)); then
    cancelled=true
    FAIL_REASON="cancelled (signal) during '${STAGE}'"
  fi
  [[ -n "${FAIL_REASON}" ]] || FAIL_REASON="unexpected error during '${STAGE}' (exit ${rc})"
  log "release FAILED during '${STAGE}': ${FAIL_REASON}"
  local actions=()

  if [[ "${SERVICE_UPDATED}" == true ]]; then
    local current_td
    current_td="$(describe_service | jq -r '.taskDefinition')"
    if [[ "${current_td}" == "${NEW_TASK_DEF}" ]]; then
      log "rollback: service still on ${NEW_TASK_DEF##*/}; redeploying ${PREV_TASK_DEF##*/}"
      if aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
        --task-definition "${PREV_TASK_DEF}" >/dev/null; then
        if [[ "${cancelled}" == true ]]; then
          # The runner kills us ~10s after cancelling: issue, don't wait.
          actions+=("Redeploy of \`${PREV_TASK_DEF##*/}\` issued (not awaited: run was cancelled)")
        elif wait_for_rollout "${PREV_TASK_DEF}" "${DEPLOY_TIMEOUT_SECONDS}"; then
          actions+=("Redeployed previous task definition \`${PREV_TASK_DEF##*/}\` (stable)")
        else
          actions+=("⚠️ Redeploy of \`${PREV_TASK_DEF##*/}\` did not stabilise: ${WAIT_REASON}")
        fi
      else
        actions+=("⚠️ Could not redeploy \`${PREV_TASK_DEF##*/}\`; manual action needed")
      fi
    else
      log "rollback: ECS already restored ${current_td##*/}; no redeploy needed"
      actions+=("ECS already restored \`${current_td##*/}\` (circuit breaker / alarm rollback)")
    fi
  fi

  if [[ "${SSM_UPDATED}" == true ]]; then
    local lkg
    if lkg="$(ssm_get "${SSM_IMAGE_LKG}")" && ssm_put "${SSM_IMAGE_CURRENT}" "${lkg}"; then
      log "rollback: SSM current <- last-known-good (${lkg})"
      actions+=("SSM \`current\` reset to last-known-good \`${lkg}\`")
    else
      actions+=("⚠️ Could not reset SSM \`current\`; manual action needed")
    fi
  fi

  ((${#actions[@]})) || actions+=("Nothing to undo (failed before any change)")
  summary "### ❌ Release failed — rolled back" "" \
    "**Stage:** ${STAGE}  " \
    "**Reason:** ${FAIL_REASON}" "" \
    "| Rollback action |" "|---|"
  local a
  for a in "${actions[@]}"; do summary "| ${a} |"; done
  summary "" "Rejected image: \`${NEW_IMAGE:-n/a}\`"
  exit "${rc}"
}

trap on_exit EXIT
trap 'exit 130' INT  # turn cancellation into a normal exit so on_exit runs
trap 'exit 143' TERM

# ---------- Inputs ----------

require_env CLUSTER SERVICE NEW_IMAGE SSM_IMAGE_CURRENT SSM_IMAGE_LKG ROLLBACK_ALARMS

# Only immutable digest references are deployable; tags can be repointed.
if [[ ! "${NEW_IMAGE}" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
  die "NEW_IMAGE must be an immutable digest reference (repo@sha256:<64 hex>), got: ${NEW_IMAGE}"
fi
if [[ ! "${BAKE_MINUTES}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  die "BAKE_MINUTES must be a number, got: ${BAKE_MINUTES}"
fi
read -r -a ALARMS <<<"${ROLLBACK_ALARMS}"

# Fields RegisterTaskDefinition accepts. Allowlisted (not "delete read-only
# fields") so a new read-only field from DescribeTaskDefinition can't break us.
REGISTER_FIELDS='["family","taskRoleArn","executionRoleArn","networkMode",
  "containerDefinitions","volumes","placementConstraints","requiresCompatibilities",
  "cpu","memory","pidMode","ipcMode","proxyConfiguration","inferenceAccelerators",
  "ephemeralStorage","runtimePlatform","enableFaultInjection"]'

# ---------- 1. Record what is running now ----------

STAGE="record"
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

STAGE="register"
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

STAGE="rollout"
ssm_put "${SSM_IMAGE_CURRENT}" "${NEW_IMAGE}"
SSM_UPDATED=true
log "current <- ${NEW_IMAGE}"

aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
  --task-definition "${NEW_TASK_DEF}" >/dev/null
SERVICE_UPDATED=true
log "update-service issued; watching the PRIMARY deployment"

# ---------- 4. Watch the PRIMARY deployment (layers 1 + 2 act here) ----------

wait_for_rollout "${NEW_TASK_DEF}" "${DEPLOY_TIMEOUT_SECONDS}" || die "${WAIT_REASON}"
log "rollout COMPLETED on ${NEW_TASK_DEF##*/}"

# ---------- 5. Bake window (layer 3) ----------

STAGE="bake"
bake_seconds="$(awk -v m="${BAKE_MINUTES}" 'BEGIN { printf "%d", m * 60 }')"
bake_end=$((SECONDS + bake_seconds))
log "baking for ${BAKE_MINUTES} min; watching alarms: ${ALARMS[*]}"

while :; do
  alarms_json="$(aws cloudwatch describe-alarms --alarm-names "${ALARMS[@]}" --output json)"
  found="$(jq '.MetricAlarms | length' <<<"${alarms_json}")"
  # A missing/misnamed alarm would otherwise make the bake pass silently.
  ((found == ${#ALARMS[@]})) ||
    die "expected ${#ALARMS[@]} rollback alarms, found ${found}: check ROLLBACK_ALARMS"
  firing="$(jq -r '[.MetricAlarms[] | select(.StateValue == "ALARM") | .AlarmName] | join(", ")' <<<"${alarms_json}")"
  [[ -z "${firing}" ]] || die "rollback alarm in ALARM during bake: ${firing}"

  ((SECONDS < bake_end)) || break
  pause "${BAKE_POLL_SECONDS}"
done

STAGE="done"
log "bake passed; deployed ${NEW_IMAGE}"
