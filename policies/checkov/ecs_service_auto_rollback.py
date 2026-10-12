"""CKV_IKE_ECS_1: every ECS service must be able to roll itself back.

PASS only if the service has BOTH:
  - deployment_circuit_breaker { enable = true, rollback = true }
  - alarms { enable = true, rollback = true, alarm_names = [<at least one>] }

A release that fails health checks (circuit breaker) or degrades real traffic
(alarms) must revert automatically, without a human in the loop.
"""

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


def _first(value):
    """Checkov wraps HCL values in lists; unwrap one level."""
    if isinstance(value, list):
        return value[0] if value else None
    return value


def _is_true(value):
    value = _first(value)
    if isinstance(value, bool):
        return value
    return isinstance(value, str) and value.strip().lower() == "true"


def _block(conf, name):
    """Return the first nested block `name` as a dict, or None."""
    block = _first(conf.get(name))
    return block if isinstance(block, dict) else None


def _non_empty_list(value):
    value = _first(value)
    if isinstance(value, list):
        return any(v not in (None, "") for v in value)
    # An unresolved reference (e.g. a variable) is a non-empty expression.
    return isinstance(value, str) and value.strip() not in ("", "[]")


class ECSServiceAutoRollback(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name="Ensure ECS service auto-rolls back via circuit breaker AND CloudWatch alarms",
            id="CKV_IKE_ECS_1",
            categories=[CheckCategories.GENERAL_SECURITY],
            supported_resources=["aws_ecs_service"],
        )

    def scan_resource_conf(self, conf):
        breaker = _block(conf, "deployment_circuit_breaker")
        if not breaker or not (_is_true(breaker.get("enable")) and _is_true(breaker.get("rollback"))):
            self.details.append("deployment_circuit_breaker must set enable = true and rollback = true")
            return CheckResult.FAILED

        alarms = _block(conf, "alarms")
        if not alarms or not (_is_true(alarms.get("enable")) and _is_true(alarms.get("rollback"))):
            self.details.append("alarms block must set enable = true and rollback = true")
            return CheckResult.FAILED

        if not _non_empty_list(alarms.get("alarm_names")):
            self.details.append("alarms.alarm_names must list at least one alarm")
            return CheckResult.FAILED

        return CheckResult.PASSED


check = ECSServiceAutoRollback()
