#!/usr/bin/env bash
# Regression tests for custom Checkov policies.
# Each fixture dir is named pass_* or fail_*; CKV_IKE_ECS_1 must agree.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
checks_dir="$(dirname "$here")"
failures=0

for dir in "$here"/*/; do
  name="$(basename "$dir")"
  expected="${name%%_*}"
  # Judge by the check's own verdict, not the exit code alone, so a Checkov
  # crash or parse error can never masquerade as an expected "fail".
  out="$(checkov -d "$dir" --framework terraform --external-checks-dir "$checks_dir" \
           --check CKV_IKE_ECS_1 --compact 2>&1 || true)"
  if grep -q "PASSED for resource: aws_ecs_service.fixture" <<<"$out"; then
    actual=pass
  elif grep -q "FAILED for resource: aws_ecs_service.fixture" <<<"$out"; then
    actual=fail
  else
    actual=error
    echo "$out"
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "ok    $name ($actual)"
  else
    echo "FAIL  $name: expected $expected, got $actual"
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  echo "$failures policy test(s) failed"
  exit 1
fi
echo "all policy tests passed"
