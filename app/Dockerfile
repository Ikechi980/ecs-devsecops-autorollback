# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# ^ The BuildKit frontend is code that runs at build time; pinned by digest
#   like every other dependency.

# Base image pinned by tag AND digest: the tag documents intent, the digest is
# what actually gets pulled, so an upstream retag can't change our build.
# The digest is the multi-arch index, so it works for both arm64 and amd64.
# To refresh it:
#   docker buildx imagetools inspect python:3.12.15-slim-trixie --format '{{json .Manifest.Digest}}'
ARG BASE_IMAGE=python:3.12.15-slim-trixie@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

# ---------- build stage: install deps into an isolated venv ----------
FROM ${BASE_IMAGE} AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build
COPY requirements.txt .

# --require-hashes: every package (incl. transitive) must match the lockfile hash.
# --only-binary: no sdists, so no arbitrary setup.py runs at build time.
# pip is removed from the venv afterwards; the runtime never needs it.
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --only-binary=:all: -r requirements.txt \
 && /opt/venv/bin/pip uninstall -y pip

# ---------- runtime stage ----------
FROM ${BASE_IMAGE} AS runtime

ARG APP_VERSION=dev
ARG FAIL_HEALTH=false

LABEL org.opencontainers.image.title="ecs-devsecops-autorollback" \
      org.opencontainers.image.version="${APP_VERSION}"

ENV APP_VERSION=${APP_VERSION} \
    FAIL_HEALTH=${FAIL_HEALTH} \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Pull in Debian security fixes released after the base image was built, then
# remove the system pip (unused at runtime, and a recurring CVE source).
# Create a locked-down service account: fixed UID/GID 10001, no home dir,
# nologin shell, system account (no password aging / login).
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y --root-user-action=ignore pip \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home \
            --home-dir /nonexistent --shell /usr/sbin/nologin app

COPY --from=build /opt/venv /opt/venv

# /tmp is the only writable path at runtime (read-only root FS in ECS).
# Fargate creates bind-mount volumes as root:root 0755 unless the image
# declares the path as a VOLUME, in which case it copies the image's
# ownership/mode. 1777 (sticky, world-writable) = standard /tmp semantics,
# so UID 10001 can create gunicorn's worker heartbeat files.
RUN chmod 1777 /tmp
VOLUME ["/tmp"]

# Code is owned by root and only readable by the app user, so a compromised
# process can't modify what it runs.
WORKDIR /srv
COPY --chown=root:root --chmod=0444 app.py .

USER 10001:10001

EXPOSE 8080

# slim has no curl: use Python's stdlib. urlopen raises on non-2xx -> exit 1.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2); sys.exit(0)"]

# Exec form (no shell) so gunicorn is PID 1 and receives SIGTERM from ECS.
# --worker-tmp-dir /tmp: heartbeat files live on the /tmp volume, which is the
# only writable path once the root filesystem is read-only in ECS.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", \
     "--worker-tmp-dir", "/tmp", "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
