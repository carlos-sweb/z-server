#!/usr/bin/env bash
# Build localhost/z-server:0.2.0 and drop dangling layers from the previous tag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IMAGE="${IMAGE:-localhost/z-server:0.2.0}"
if [[ "${1:-}" == "--prune-only" ]]; then
  podman image prune -f --filter 'dangling=true'
  podman volume prune -f
  podman system df
  exit 0
fi
podman build --format docker -t "$IMAGE" .
podman image prune -f --filter 'dangling=true'
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^localhost/z-server:0.2.0 ' || true
podman system df
