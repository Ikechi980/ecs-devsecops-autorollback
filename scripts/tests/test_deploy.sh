#!/usr/bin/env bash
# Tests for scripts/deploy.sh against a stateful mock aws CLI (tests/bin/aws).
# Each scenario asserts: exit code, the task definition the service ends on,
# and the SSM `current` digest afterwards.
#
#   bash scripts/tests/test_deploy.sh            # all scenarios
#   VERBOSE=1 bash scripts/tests/test_deploy.sh  # also print deploy.sh output
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
deploy="${here}/../deploy.sh"
OLD="repo@sha256:$(printf 'a%.0s' {1..64})"
NEW="repo@sha256:$(printf 'b%.0s' {1..64})"
PREV_TD="arn:aws:ecs:us-east-1:1:task-definition/app:1"
failures=0

setup_state() {
  cat >"$1" <<EOF
{
  "prev_td": "${PREV_TD}",
  "service_td": "${PREV_TD}",
  "ssm": {"/app/image/current": "${OLD}", "/app/image/last-known-good": "bootstrap"},
  "taskdefs": {"${PREV_TD}": {"taskDefinitionArn": "${PREV_TD}", "family": "app", "revision": 1,
     "status": "ACTIVE", "registeredAt": "x", "requiresAttributes": [], "compatibilities": ["FARGATE"],
     "cpu": "256", "memory": "512", "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
     "containerDefinitions": [{"name": "app", "image": "bootstrap@sha256:0", "command": ["python", "-c", "x"]}]}},
  "deployments": [{"status": "PRIMARY", "taskDefinition": "${PREV_TD}", "rolloutState": "COMPLETED",
     "runningCount": 2, "pendingCount": 0, "failedTasks": 0}]
}
EOF
}

# run_case <scenario> <want_exit> <want_td_suffix> <want_ssm_current> [cancel_after_seconds]
run_case() {
  local scenario="$1" want_rc="$2" want_td="$3" want_ssm="$4" cancel_after="${5:-}"
  local work rc td ssm cmd_ok=true
  work="$(mktemp -d)"
  setup_state "${work}/state.json"

  (
    export PATH="${here}/bin:${PATH}" MOCK_STATE="${work}/state.json" MOCK_SCENARIO="${scenario}"
    export CLUSTER=c SERVICE=s NEW_IMAGE="${NEW}" ROLLBACK_ALARMS="app-5xx app-p99"
    export SSM_IMAGE_CURRENT=/app/image/current SSM_IMAGE_LKG=/app/image/last-known-good
    export POLL_SECONDS=0 DEPLOY_TIMEOUT_SECONDS=30 BAKE_MINUTES=0.05 BAKE_POLL_SECONDS=0
    export GITHUB_STEP_SUMMARY="${work}/summary.md"
    if [[ -n "${cancel_after}" ]]; then
      POLL_SECONDS=1 bash "${deploy}" &
      pid=$!
      sleep "${cancel_after}"
      kill -TERM "${pid}"
      wait "${pid}"
    else
      bash "${deploy}"
    fi
  ) >"${work}/out.log" 2>&1
  rc=$?

  td="$(jq -r '.service_td | split("/") | last' "${work}/state.json")"
  ssm="$(jq -r '.ssm["/app/image/current"]' "${work}/state.json")"
  # On success the bootstrap `command` must not survive into the new revision.
  if jq -e '.registered.containerDefinitions[0] | has("command")' "${work}/state.json" >/dev/null 2>&1; then
    cmd_ok=false
  fi

  if [[ "${rc}" == "${want_rc}" && "${td}" == "${want_td}" && "${ssm}" == "${want_ssm}" && "${cmd_ok}" == true ]]; then
    echo "ok    ${scenario}: exit=${rc} service=${td} ssm_current=${ssm:0:20}..."
  else
    echo "FAIL  ${scenario}: exit=${rc} (want ${want_rc}) service=${td} (want ${want_td})" \
      "ssm_current=${ssm:0:20}... (want ${want_ssm:0:20}...) command_dropped=${cmd_ok}"
    sed 's/^/      /' "${work}/out.log"
    failures=$((failures + 1))
  fi
  if [[ -n "${VERBOSE:-}" ]]; then
    sed 's/^/      /' "${work}/out.log"
    [[ -s "${work}/summary.md" ]] && sed 's/^/      | /' "${work}/summary.md"
  fi
  rm -rf "${work}"
}

#        scenario       exit  service  ssm current  cancel
run_case success        0     app:2    "${NEW}"
run_case breaker        1     app:1    "${OLD}"
run_case alarm_in_bake  1     app:1    "${OLD}"
run_case missing_alarm  1     app:1    "${OLD}"
run_case cancel         143   app:1    "${OLD}"  2

if ((failures > 0)); then
  echo "${failures} deploy test(s) failed"
  exit 1
fi
echo "all deploy tests passed"
