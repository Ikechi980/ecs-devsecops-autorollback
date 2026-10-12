# Fixture for CKV_IKE_ECS_1 — expected: fail
resource "aws_ecs_service" "fixture" {
  name            = "fixture"
  cluster         = "fixture"
  task_definition = "fixture:1"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
