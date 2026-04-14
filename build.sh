#!/bin/bash
set -e

# Build all GoSat Docker images.
#
# Usage:
#   ./build.sh                           # build all for native arch (arm64 on Apple Silicon)
#   ./build.sh v1.2.3                    # build all, tag as v1.2.3
#   PLATFORM=linux/amd64 ./build.sh      # build for x86 (production)
#   PLATFORM=linux/arm64 ./build.sh      # build for arm64 (dev on Apple Silicon)
#
#   REGISTRY=registry.digitalocean.com/gosat PLATFORM=linux/amd64 PUSH=1 ./build.sh v1.0.0
#
# Shortcuts:
#   ./build.sh --dev                     # arm64, localhost registry, latest tag
#   ./build.sh --prod v1.0.0             # amd64, push to REGISTRY

# ─── Parse shortcuts ─────────────────────────────────────────────────────────

if [ "$1" = "--dev" ]; then
  shift
  PLATFORM="${PLATFORM:-linux/arm64}"
  REGISTRY="${REGISTRY:-gosat}"
  TAG="${1:-latest}"
elif [ "$1" = "--prod" ]; then
  shift
  PLATFORM="${PLATFORM:-linux/amd64}"
  PUSH="${PUSH:-1}"
  TAG="${1:-latest}"
else
  TAG="${1:-latest}"
fi

PLATFORM="${PLATFORM:-linux/$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')}"
REGISTRY="${REGISTRY:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Image prefix: "registry/name" or just "name" if registry is empty
PREFIX="${REGISTRY:+${REGISTRY}/}"

echo "=== Building GoSat images ==="
echo "Registry:  ${REGISTRY:-<local>}"
echo "Tag:       $TAG"
echo "Platform:  $PLATFORM"
echo ""

DOCKER_BUILD="docker build --platform $PLATFORM"

# ─── Node.js services ────────────────────────────────────────────────────────

NODE_SERVICES=(
  gosat-api
  gosat-dispatcher
  gosat-sms
  gosat-caller
  gosat-geocoder
  gosat-shortener
  gosat-telegram-bot
)

for svc in "${NODE_SERVICES[@]}"; do
  echo "→ Building $svc ..."
  $DOCKER_BUILD \
    -f "$ROOT/gosat-k8s/dockerfiles/Dockerfile.node" \
    --build-arg SERVICE_DIR="$svc" \
    -t "$PREFIX$svc:$TAG" \
    "$ROOT"
  echo "  ✓ $PREFIX$svc:$TAG"
done

# ─── Go service ──────────────────────────────────────────────────────────────

echo "→ Building gosat-server ..."
$DOCKER_BUILD \
  -f "$ROOT/gosat-k8s/dockerfiles/Dockerfile.go" \
  -t "${PREFIX}gosat-server:$TAG" \
  "$ROOT/gosat-server"
echo "  ✓ ${PREFIX}gosat-server:$TAG"

# ─── Web (Vue.js) ────────────────────────────────────────────────────────────

echo "→ Building gosat-web ..."
$DOCKER_BUILD \
  -f "$ROOT/gosat-k8s/dockerfiles/Dockerfile.web" \
  -t "${PREFIX}gosat-web:$TAG" \
  "$ROOT/gosat-web"
echo "  ✓ ${PREFIX}gosat-web:$TAG"

echo ""
echo "=== All images built ($PLATFORM) ==="

# ─── Optional push ───────────────────────────────────────────────────────────

if [ "${PUSH}" = "1" ]; then
  echo ""
  echo "=== Pushing images ==="
  for svc in "${NODE_SERVICES[@]}" gosat-server gosat-web; do
    echo "→ Pushing $svc ..."
    docker push "$PREFIX$svc:$TAG"
  done
  echo "=== All images pushed ==="
fi
