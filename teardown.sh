#!/bin/bash
set -euo pipefail

# Tear down all GoSat releases + CRs + PVCs in the target cluster, so a
# subsequent `helmfile -e <env> sync` starts from a clean state.
#
# Does NOT touch cluster-wide operators (OLM, cert-manager, RabbitMQ operator)
# installed by install-operators.sh — those survive the teardown.
#
# Usage:
#   ./teardown.sh <dev|prod>           # preserves the gosat namespace, re-apply secrets.yaml after
#   ./teardown.sh <dev|prod> --nuke    # also deletes the gosat namespace
#
# Safety: the script forces the expected kube-context (dev→minikube,
# prod→do-fra1-gosat1), verifies it, and asks for confirmation before
# doing anything destructive.

DEV_CONTEXT="minikube"
PROD_CONTEXT="do-fra1-gosat1"

NUKE=0

if [ $# -lt 1 ]; then
  echo "Usage: $0 <dev|prod> [--nuke]" >&2
  exit 1
fi

case "$1" in
  dev)  EXPECTED_CONTEXT="$DEV_CONTEXT"; ENV="minikube" ;;
  prod) EXPECTED_CONTEXT="$PROD_CONTEXT"; ENV="production" ;;
  *)
    echo "Unknown environment: $1 (expected: dev | prod)" >&2
    exit 1
    ;;
esac
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --nuke) NUKE=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# Ensure the expected context exists and switch to it.
AVAILABLE_CONTEXTS="$(kubectl config get-contexts -o name)"
FOUND=0
while IFS= read -r ctx; do
  [ "$ctx" = "$EXPECTED_CONTEXT" ] && FOUND=1 && break
done <<< "$AVAILABLE_CONTEXTS"

if [ "$FOUND" -ne 1 ]; then
  echo "✗ Context '$EXPECTED_CONTEXT' is not defined in your kubeconfig." >&2
  echo "  Available contexts:" >&2
  echo "$AVAILABLE_CONTEXTS" | sed 's/^/    /' >&2
  exit 1
fi

kubectl config use-context "$EXPECTED_CONTEXT" >/dev/null
CURRENT_CONTEXT="$(kubectl config current-context)"
if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  echo "✗ Failed to switch context. current='$CURRENT_CONTEXT'." >&2
  exit 1
fi

API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

echo "=== Target cluster ==="
echo "  Environment:   $ENV"
echo "  Context:       $CURRENT_CONTEXT"
echo "  API server:    $API_SERVER"
echo "  Mode:          $([ $NUKE -eq 1 ] && echo 'NUKE (delete namespace)' || echo 'soft (preserve namespace)')"
echo ""
echo "This will destroy all GoSat releases, operator CRs, and PVCs in"
echo "namespace 'gosat'. Data on persistent volumes will be lost."
echo ""

if [ "${ASSUME_YES:-0}" != "1" ]; then
  read -r -p "Type 'yes' to continue: " reply
  if [ "$reply" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

KUBECTL="kubectl --context=$EXPECTED_CONTEXT"
HELMFILE="helmfile --kube-context=$EXPECTED_CONTEXT -e $ENV"

echo ""
echo "→ Destroying Helmfile releases..."
$HELMFILE destroy || true

echo ""
echo "→ Removing operator-managed custom resources..."
$KUBECTL -n gosat delete mongodbcommunity --all --ignore-not-found
$KUBECTL -n gosat delete rabbitmqcluster --all --ignore-not-found
$KUBECTL -n gosat delete opensearchcluster --all --ignore-not-found

echo ""
echo "→ Removing PVCs..."
$KUBECTL -n gosat delete pvc --all --ignore-not-found

echo ""
echo "→ Removing operator-generated secrets..."
$KUBECTL -n gosat delete secret \
  opensearch-admin-password opensearch-admin-cert opensearch-ca \
  opensearch-dashboards-password opensearch-http-cert \
  opensearch-security-config-generated opensearch-transport-cert \
  mongodb-gosat-password mongodb-gosat-scram mongodb-config \
  rabbitmq-default-user rabbitmq-erlang-cookie rabbitmq-server-conf \
  --ignore-not-found

if [ "$NUKE" -eq 1 ]; then
  echo ""
  echo "→ Deleting namespace 'gosat'..."
  $KUBECTL delete namespace gosat --ignore-not-found
fi

echo ""
echo "=== Teardown complete on '$CURRENT_CONTEXT' ==="
echo ""
echo "Next steps:"
if [ "$NUKE" -eq 1 ]; then
  echo "  1. kubectl create namespace gosat"
  echo "  2. kubectl -n gosat apply -f secrets.yaml"
  echo "  3. helmfile -e $ENV sync"
else
  echo "  1. (re-apply your own secrets if needed: kubectl -n gosat apply -f secrets.yaml)"
  echo "  2. helmfile -e $ENV sync"
fi
