#!/bin/bash
set -euo pipefail

# Migrate MongoDB from an external source (e.g. GCP VM) to the DOKS-managed
# MongoDB cluster (MongoDBCommunity operator) with minimal downtime.
#
# Strategy:
#   1. Take an initial mongodump from the source.
#   2. Restore it on the destination.
#   3. Start mongomirror to keep the destination in sync via oplog tailing.
#   4. When you are ready, stop the apps writing to source, wait for lag=0,
#      stop mongomirror, repoint apps to the new cluster.
#
# Usage:
#   ./migrate-mongo-to-doks.sh <env> <source_uri>
#
#   env         dev | prod (selects kube context: minikube | do-fra1-gosat1)
#   source_uri  e.g. mongodb://user:pass@gcp-mongo:27017/?replicaSet=rs0
#
# Requirements (install on the host running this script):
#   - mongosh, mongodump, mongorestore, mongomirror, kubectl, jq
#   - network reachability: source MongoDB AND DOKS api server
#   - mongomirror download:
#     https://www.mongodb.com/try/download/database-tools
#
# Phases are interactive — at each ⏸ you can inspect state before continuing.

DEV_CONTEXT="minikube"
PROD_CONTEXT="do-fra1-gosat1"
NAMESPACE="gosat"
DEST_PORT_LOCAL="27018"          # local port for DOKS port-forward (avoid clash with source)
WORKDIR="${WORKDIR:-/tmp/gosat-mongo-migration}"
DUMP_FILE="$WORKDIR/initial.gz"
MIRROR_LOG="$WORKDIR/mongomirror.log"
MIRROR_HTTP_PORT=8000

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

# ─── safety: pin context ─────────────────────────────────────────────────────

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

for bin in mongosh mongodump mongorestore mongomirror jq kubectl; do
  command -v "$bin" >/dev/null || { echo "✗ missing tool: $bin" >&2; exit 1; }
done

# ─── destination credentials ─────────────────────────────────────────────────

echo ""
echo "→ reading DOKS MongoDB admin password from secret"
DEST_PW="$($KUBECTL get secret mongodb-gosat-password -o jsonpath='{.data.password}' | base64 -d)"
DEST_USER="gosat"
DEST_AUTH_DB="admin"

# ─── port-forward to DOKS in background ──────────────────────────────────────

echo "→ port-forward svc/mongodb-svc → localhost:$DEST_PORT_LOCAL"
$KUBECTL port-forward svc/mongodb-svc "$DEST_PORT_LOCAL:27017" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true; [ -n "${MIRROR_PID:-}" ] && kill $MIRROR_PID 2>/dev/null || true' EXIT
sleep 3

DEST_URI="mongodb://${DEST_USER}:${DEST_PW}@localhost:${DEST_PORT_LOCAL}/?authSource=${DEST_AUTH_DB}&directConnection=true"

echo "→ verifying connectivity"
mongosh "$SOURCE_URI" --quiet --eval 'db.adminCommand({ping:1})' >/dev/null
mongosh "$DEST_URI" --quiet --eval 'db.adminCommand({ping:1})' >/dev/null
echo "  ok"

# ─── phase 1: snapshot ───────────────────────────────────────────────────────

echo ""
echo "═══ Phase 1/3 — initial dump ═══"
echo "Capturing source oplog timestamp BEFORE the dump (mongomirror needs it)…"
mongosh "$SOURCE_URI" --quiet --eval '
  const ts = db.getSiblingDB("local").oplog.rs.find().sort({$natural:-1}).limit(1).next().ts;
  print(JSON.stringify({t: ts.t, i: ts.i}))
' > "$WORKDIR/start.ts"
echo "  start ts: $(cat $WORKDIR/start.ts)"

if [ -f "$DUMP_FILE" ]; then
  echo "  dump file already exists at $DUMP_FILE — skipping (delete it to redo)"
else
  echo "→ mongodump → $DUMP_FILE (this may take hours on 100GB)"
  mongodump --uri="$SOURCE_URI" --gzip --archive="$DUMP_FILE"
fi

# ─── phase 2: restore ────────────────────────────────────────────────────────

echo ""
echo "═══ Phase 2/3 — restore on DOKS ═══"
read -r -p "Restore now? Will DROP existing collections on destination. [yes/N] " r
if [ "$r" = "yes" ]; then
  mongorestore --uri="$DEST_URI" --gzip --archive="$DUMP_FILE" --drop \
    --nsExclude='admin.*' --nsExclude='config.*' --nsExclude='local.*'
else
  echo "  skipped restore"
fi

# ─── phase 3: continuous oplog tail with mongomirror ─────────────────────────

echo ""
echo "═══ Phase 3/3 — continuous sync with mongomirror ═══"
echo "starting mongomirror in background; logs → $MIRROR_LOG"
echo "lag is exposed at http://localhost:$MIRROR_HTTP_PORT"
echo ""

# extract host[:port] and credentials from source URI for mongomirror flags
nohup mongomirror \
  --host "$(echo "$SOURCE_URI" | sed -E 's|^mongodb://([^/]+).*|\1|')" \
  --destination "localhost:${DEST_PORT_LOCAL}" \
  --destinationUsername "$DEST_USER" \
  --destinationPassword "$DEST_PW" \
  --destinationAuthenticationDatabase "$DEST_AUTH_DB" \
  --httpStatusPort "$MIRROR_HTTP_PORT" \
  --noIndexRestore \
  --oplogPath "$WORKDIR/oplog" \
  >> "$MIRROR_LOG" 2>&1 &
MIRROR_PID=$!

echo "mongomirror PID: $MIRROR_PID"
echo ""
echo "Watch the lag:"
echo "  curl -s http://localhost:$MIRROR_HTTP_PORT | jq"
echo ""
echo "When lag is steady, perform the cutover:"
echo "  1. scale apps writing to source down to 0"
echo "  2. wait until lag = 0"
echo "  3. press <enter> here to stop mongomirror cleanly"
echo "  4. restart apps pointed at the new cluster"
echo ""
read -r -p "Press <enter> when ready to stop mongomirror… "
kill "$MIRROR_PID" 2>/dev/null || true
wait "$MIRROR_PID" 2>/dev/null || true
echo "→ mongomirror stopped"

echo ""
echo "═══ Migration complete ═══"
echo "Verify counts on destination, then redeploy your apps."
echo "Quick sanity check:"
echo "  mongosh \"\$DEST_URI\" --eval 'db.getSiblingDB(\"gosat\").stats()'"
