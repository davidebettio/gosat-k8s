#!/bin/bash
set -euo pipefail

# Install Kubernetes operators required by GoSat.
# Run once per cluster before `helmfile sync`.
#
# Usage:
#   ./install-operators.sh dev     # -> context: minikube
#   ./install-operators.sh prod    # -> context: do-fra1-gosat1
#
# The environment is mandatory: the script refuses to run if the current
# kube-context does not match the expected one for the chosen environment,
# so it cannot install on a wrong cluster by mistake.

DEV_CONTEXT="minikube"
PROD_CONTEXT="do-fra1-gosat1"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <dev|prod>" >&2
  exit 1
fi

case "$1" in
  dev)  EXPECTED_CONTEXT="$DEV_CONTEXT" ;;
  prod) EXPECTED_CONTEXT="$PROD_CONTEXT" ;;
  *)
    echo "Unknown environment: $1 (expected: dev | prod)" >&2
    exit 1
    ;;
esac

# Ensure the expected context exists in kubeconfig.
# (Capturing first avoids pipefail + grep -q early-close edge cases.)
AVAILABLE_CONTEXTS="$(kubectl config get-contexts -o name)"
FOUND=0
while IFS= read -r ctx; do
  if [ "$ctx" = "$EXPECTED_CONTEXT" ]; then
    FOUND=1
    break
  fi
done <<< "$AVAILABLE_CONTEXTS"

if [ "$FOUND" -ne 1 ]; then
  echo "✗ Context '$EXPECTED_CONTEXT' is not defined in your kubeconfig." >&2
  echo "  Available contexts:" >&2
  echo "$AVAILABLE_CONTEXTS" | sed 's/^/    /' >&2
  exit 1
fi

# Switch context explicitly — no reliance on whatever was current.
kubectl config use-context "$EXPECTED_CONTEXT" >/dev/null

CURRENT_CONTEXT="$(kubectl config current-context)"
if [ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]; then
  echo "✗ Failed to switch context. Current='$CURRENT_CONTEXT' expected='$EXPECTED_CONTEXT'." >&2
  exit 1
fi

# Double-check by reading the real API server URL and confirming.
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

echo "=== Target cluster ==="
echo "  Environment: $1"
echo "  Context:     $CURRENT_CONTEXT"
echo "  API server:  $API_SERVER"
echo ""

if [ "${ASSUME_YES:-0}" != "1" ]; then
  read -r -p "Proceed with operator install on this cluster? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# From here on, every kubectl call is explicitly pinned to $EXPECTED_CONTEXT
# so even if something else changes the current context mid-run we stay safe.
KUBECTL="kubectl --context=$EXPECTED_CONTEXT"

echo ""
echo "=== Installing operators ==="

# ─── OLM (Operator Lifecycle Manager) ────────────────────────────────────────
OLM_VERSION="${OLM_VERSION:-v0.28.0}"
echo ""
echo "→ OLM ${OLM_VERSION}..."
if $KUBECTL get deployment -n olm olm-operator &>/dev/null; then
  echo "  Already installed, skipping."
else
  $KUBECTL apply --server-side -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}/crds.yaml"
  $KUBECTL apply --server-side -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}/olm.yaml"
  $KUBECTL -n olm rollout status deployment/olm-operator --timeout=120s
  $KUBECTL -n olm rollout status deployment/catalog-operator --timeout=120s
  echo "  OLM installed."
fi

# ─── cert-manager (required by OpenSearch operator) ─────────────────────────
CERTMANAGER_VERSION="${CERTMANAGER_VERSION:-v1.17.2}"
echo ""
echo "→ cert-manager ${CERTMANAGER_VERSION}..."
if $KUBECTL get deployment -n cert-manager cert-manager &>/dev/null; then
  echo "  Already installed, skipping."
else
  $KUBECTL apply --server-side -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMANAGER_VERSION}/cert-manager.yaml"
  $KUBECTL -n cert-manager rollout status deployment/cert-manager --timeout=120s
  $KUBECTL -n cert-manager rollout status deployment/cert-manager-webhook --timeout=120s
  echo "  cert-manager installed."
fi

# ─── RabbitMQ Cluster Operator ───────────────────────────────────────────────
RABBITMQ_VERSION="${RABBITMQ_VERSION:-v2.20.0}"
echo ""
echo "→ RabbitMQ Cluster Operator ${RABBITMQ_VERSION}..."
if $KUBECTL get deployment -n rabbitmq-system rabbitmq-cluster-operator &>/dev/null; then
  echo "  Already installed, skipping."
else
  $KUBECTL apply --server-side -f "https://github.com/rabbitmq/cluster-operator/releases/download/${RABBITMQ_VERSION}/cluster-operator.yml"
  $KUBECTL -n rabbitmq-system rollout status deployment/rabbitmq-cluster-operator --timeout=120s
  echo "  RabbitMQ operator installed."
fi

echo ""
echo "=== All operators ready on '$CURRENT_CONTEXT' ==="
echo "You can now run: helmfile -e $1 sync"
