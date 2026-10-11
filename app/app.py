import os

from flask import Flask, jsonify

SERVICE_NAME = "ecs-devsecops-autorollback"

app = Flask(__name__)


def _env_true(name: str) -> bool:
    return os.environ.get(name, "false").strip().lower() in ("1", "true", "yes")


@app.get("/")
def index():
    return jsonify(service=SERVICE_NAME, version=os.environ.get("APP_VERSION", "dev"))


@app.get("/health")
def health():
    # FAIL_HEALTH=true makes the release unhealthy on purpose (rollback drill).
    if _env_true("FAIL_HEALTH"):
        return jsonify(status="fail"), 500
    return jsonify(status="ok"), 200
