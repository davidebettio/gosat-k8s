#!/bin/bash
set -euo pipefail

# Migrate MongoDB from an external source (e.g. GCP VM) to the DOKS-managed
# MongoDB cluster using mongosync (official Cluster-to-Cluster Sync).
# Zero/minimal downtime: initial copy + continuous oplog replay, you commit
# when ready.
#
# mongomirror is EOL (2024). Install mongosync instead:
#   https://www.mongodb.com/try/download/cluster-to-cluster-sync
#
# Usage:
#   ./migrate-mongo-to-doks.sh <env> <source_uri>
#
#   env         dev | prod (selects kube context: minikube | do-fra1-gosat1)
#   source_uri  e.g. mongodb://user:pass@gcp-mongo:27017/?replicaSet=rs0
#
# Requirements on the host running this script:
#   - mongosync (binary in PATH)
#   - mongosh, kubectl, jq, curl
#   - network reachability: source MongoDB AND DOKS API
#   - both clusters must be replica sets (even single-node)
#   - MongoDB 6.0+ on both source and destination
#
# Flow:
#   1. Port-forward to DOKS MongoDB
#   2. Launch mongosync as a background daemon (HTTP on :27182)
#   3. POST /api/v1/start to begin the initial sync
#   4. Watch lag via /api/v1/progress
#   5. When ready, POST /api/v1/commit to finalize the cutover

DEV_CONTEXT="minikube"
PROD_CONTEXT="do-fra1-gosat1"
NAMESPACE="gosat"
DEST_PORT_LOCAL="27018"
MONGOSYNC_PORT="27182"
WORKDIR="${WORKDIR:-/tmp/gosat-mongo-migration}"
MONGOSYNC_LOG="$WORKDIR/mongosync.log"

# ─── arg parsing ─────────────────────────────────────────────────────────────

if [ $# -lt 2 ]; then
  echo "Usage: $0 <dev|prod> <source_mongodb_uri>" >&2
  exit 1
fi

case "$1" in
  dev)  EXPECTED_CONTEXT="$DEV_CONTEXT" ;;
  prod) EXPECTED_CONTEXT="$PROD_CONTEXT" ;;
  *)    echo "Unknown env: $1" >&2; exit 1 ;;
esac
SOURCE_URI="$2"

# ─── context pin ─────────────────────────────────────────────────────────────

if ! kubectl config get-contexts -o name | grep -qx "$EXPECTED_CONTEXT"; then
  echo "✗ Context '$EXPECTED_CONTEXT' missing in kubeconfig." >&2
  exit 1
fi
kubectl config use-context "$EXPECTED_CONTEXT" >/dev/null
KUBECTL="kubectl --context=$EXPECTED_CONTEXT -n $NAMESPACE"

API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "=== Migration target ==="
echo "  Context:    $EXPECTED_CONTEXT"
echo "  API server: $API_SERVER"
echo "  Source URI: ${SOURCE_URI//:*@/:***@}"
echo ""
read -r -p "Continue? [yes/N] " r; [ "$r" = "yes" ] || { echo "abort"; exit 1; }

mkdir -p "$WORKDIR"

# ─── tool checks ─────────────────────────────────────────────────────────────

for bin in mongosync mongosh jq kubectl curl; do
  command -v "$bin" >/dev/null \
    || { echo "✗ missing tool: $bin. Install from https://www.mongodb.com/try/download/cluster-to-cluster-sync"; exit 1; }
done

# ─── destination credentials ─────────────────────────────────────────────────

echo "→ reading DOKS MongoDB admin password from secret"
DEST_PW="$($KUBECTL get secret mongodb-gosat-password -o jsonpath='{.data.password}' | base64 -d)"
DEST_USER="gosat"
DEST_AUTH_DB="admin"

# ─── port-forward to DOKS ────────────────────────────────────────────────────

echo "→ port-forward svc/mongodb-svc → localhost:$DEST_PORT_LOCAL"
$KUBECTL port-forward svc/mongodb-svc "$DEST_PORT_LOCAL:27017" >/dev/null 2>&1 &
PF_PID=$!
MONGOSYNC_PID=""
trap 'kill $PF_PID 2>/dev/null || true; [ -n "$MONGOSYNC_PID" ] && kill $MONGOSYNC_PID 2>/dev/null || true' EXIT
sleep 3

DEST_URI="mongodb://${DEST_USER}:${DEST_PW}@localhost:${DEST_PORT_LOCAL}/?authSource=${DEST_AUTH_DB}&directConnection=true"

echo "→ verifying connectivity"
mongosh "$SOURCE_URI" --quiet --eval 'db.adminCommand({ping:1})' >/dev/null
mongosh "$DEST_URI" --quiet --eval 'db.adminCommand({ping:1})' >/dev/null
echo "  ok"

# ─── phase 1: start mongosync daemon ─────────────────────────────────────────

echo ""
echo "═══ Phase 1/3 — launching mongosync ═══"
nohup mongosync \
  --cluster0 "$SOURCE_URI" \
  --cluster1 "$DEST_URI" \
  --logPath "$WORKDIR/mongosync-logs" \
  --port "$MONGOSYNC_PORT" \
  --noTLS \
  >> "$MONGOSYNC_LOG" 2>&1 &
MONGOSYNC_PID=$!

echo "  pid=$MONGOSYNC_PID — waiting for HTTP API on :$MONGOSYNC_PORT"
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$MONGOSYNC_PORT/api/v1/progress" >/dev/null 2>&1; then
    echo "  ok"
    break
  fi
  sleep 1
done

# ─── phase 2: start the sync ─────────────────────────────────────────────────

echo ""
echo "═══ Phase 2/3 — starting initial sync ═══"
curl -sf -X POST "http://localhost:$MONGOSYNC_PORT/api/v1/start" \
  -H "Content-Type: application/json" \
  -d '{"source":"cluster0","destination":"cluster1"}' \
  | jq .

echo ""
echo "sync started. Monitor progress with:"
echo "  watch 'curl -s http://localhost:$MONGOSYNC_PORT/api/v1/progress | jq'"
echo ""
echo "Key fields in /progress:"
echo "  state           → IDLE → RUNNING → COMMITTING → COMMITTED"
echo "  canCommit       → true when the initial copy is complete and we are"
echo "                    tailing oplog"
echo "  lagTimeSeconds  → replication lag in seconds"
echo ""

# ─── phase 3: cutover ────────────────────────────────────────────────────────

echo "═══ Phase 3/3 — cutover ═══"
echo "When you are ready:"
echo "  1. scale apps writing to source down to 0"
echo "  2. wait until /progress shows lagTimeSeconds=0 and canCommit=true"
echo "  3. press <enter> here to send commit"
echo "  4. redeploy apps against the new cluster"
echo ""
read -r -p "Press <enter> to send commit… "

curl -sf -X POST "http://localhost:$MONGOSYNC_PORT/api/v1/commit" \
  -H "Content-Type: application/json" -d '{}' \
  | jq .

echo ""
echo "→ waiting for state=COMMITTED"
while true; do
  state="$(curl -s "http://localhost:$MONGOSYNC_PORT/api/v1/progress" | jq -r '.progress.state')"
  echo "  state=$state"
  [ "$state" = "COMMITTED" ] && break
  sleep 3
done

echo ""
echo "═══ Migration complete ═══"
echo "Quick sanity check:"
echo "  mongosh \"$DEST_URI\" --eval 'db.getSiblingDB(\"gosat\").stats()'"
