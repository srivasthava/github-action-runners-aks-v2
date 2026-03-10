#!/bin/bash
###############################################################################
# entrypoint.sh — GitHub Actions Runner with DinD (ARC v2 compatible)
#
# ARC v2 sets the container command to /home/runner/run.sh.
# This entrypoint starts the Docker daemon first, then exec's into
# whatever command ARC provides (or falls back to manual registration).
#
# Environment variables:
#   DISABLE_DIND  — Set to "true" to skip Docker daemon startup
#   DOCKER_MTU    — Docker network MTU (default: 1450 for overlay networks)
###############################################################################
set -euo pipefail

DOCKER_MTU="${DOCKER_MTU:-1450}"

#──────────────────────────────────────────────────────────────────────────────
# Start Docker daemon (DinD)
#──────────────────────────────────────────────────────────────────────────────
start_docker() {
    if [[ "${DISABLE_DIND:-false}" == "true" ]]; then
        echo "DinD disabled, skipping Docker daemon startup"
        return
    fi

    echo "Starting Docker daemon (DinD)..."

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "mtu": ${DOCKER_MTU},
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" },
    "features": { "buildkit": true },
    "exec-opts": ["native.cgroupdriver=cgroupfs"],
    "live-restore": false,
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 5
}
EOF

    dockerd &
    DOCKER_PID=$!

    echo "Waiting for Docker daemon..."
    local retries=30
    while ! docker info >/dev/null 2>&1; do
        if ! kill -0 "$DOCKER_PID" 2>/dev/null; then
            echo "Docker daemon failed to start"
            exit 1
        fi
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            echo "Docker daemon startup timed out"
            exit 1
        fi
        sleep 1
    done

    echo "Docker daemon ready ($(docker version --format '{{.Server.Version}}'))"
}

#──────────────────────────────────────────────────────────────────────────────
# Cleanup on exit
#──────────────────────────────────────────────────────────────────────────────
cleanup() {
    echo "Graceful shutdown..."
    if [[ -n "${DOCKER_PID:-}" ]]; then
        kill "$DOCKER_PID" 2>/dev/null || true
        wait "$DOCKER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT SIGTERM SIGINT

#──────────────────────────────────────────────────────────────────────────────
# Main
#──────────────────────────────────────────────────────────────────────────────
echo "GitHub Actions Runner — Linux DinD (ARC v2)"
echo "Node.js: $(node --version 2>/dev/null || echo 'n/a')"
echo "Docker:  starting..."

start_docker

mkdir -p /home/runner/_work

# ARC v2 injects JIT config via ACTIONS_RUNNER_INPUT_JITCONFIG env var.
# If args are passed (e.g. /home/runner/run.sh), exec them directly.
# Otherwise fall back to run.sh.
if [[ $# -gt 0 ]]; then
    exec "$@"
else
    exec /home/runner/run.sh
fi
