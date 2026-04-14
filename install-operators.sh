#!/bin/bash
set -e

# Install Kubernetes operators required by GoSat.
# Run once per cluster before `helmfile sync`.
#
# Usage:
#   ./install-operators.sh

echo "=== Installing operators ==="

# ─── OLM (Operator Lifecycle Manager) ────────────────────────────────────────
OLM_VERSION="${OLM_VERSION:-v0.28.0}"
echo ""
echo "→ OLM ${OLM_VERSION}..."
if kubectl get deployment -n olm olm-operator &>/dev/null; then
  echo "  Already installed, skipping."
else
  kubectl apply --server-side -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}/crds.yaml"
  kubectl apply --server-side -f "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}/olm.yaml"
  kubectl -n olm rollout status deployment/olm-operator --timeout=120s
  kubectl -n olm rollout status deployment/catalog-operator --timeout=120s
  echo "  OLM installed."
fi

# ─── cert-manager (required by OpenSearch operator) ─────────────────────────
CERTMANAGER_VERSION="${CERTMANAGER_VERSION:-v1.17.2}"
echo ""
echo "→ cert-manager ${CERTMANAGER_VERSION}..."
if kubectl get deployment -n cert-manager cert-manager &>/dev/null; then
  echo "  Already installed, skipping."
else
  kubectl apply --server-side -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMANAGER_VERSION}/cert-manager.yaml"
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=120s
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=120s
  echo "  cert-manager installed."
fi

# ─── RabbitMQ Cluster Operator ───────────────────────────────────────────────
RABBITMQ_VERSION="${RABBITMQ_VERSION:-v2.20.0}"
echo ""
echo "→ RabbitMQ Cluster Operator ${RABBITMQ_VERSION}..."
if kubectl get deployment -n rabbitmq-system rabbitmq-cluster-operator &>/dev/null; then
  echo "  Already installed, skipping."
else
  kubectl apply --server-side -f "https://github.com/rabbitmq/cluster-operator/releases/download/${RABBITMQ_VERSION}/cluster-operator.yml"
  kubectl -n rabbitmq-system rollout status deployment/rabbitmq-cluster-operator --timeout=120s
  echo "  RabbitMQ operator installed."
fi

echo ""
echo "=== All operators ready ==="
echo "You can now run: helmfile -e minikube sync"
