# Fixture for CKV_IKE_ECS_1 — expected: pass
resource "aws_ecs_service" "fixture" {
  name            = "fixture"
  cluster         = "fixture"
  task_definition = "fixture:1"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  alarms {
    enable      = true
    rollback    = true
    alarm_names = ["fixture-5xx"]
  }
}
