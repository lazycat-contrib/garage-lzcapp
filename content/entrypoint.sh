#!/bin/sh
set -eu

# Garage needs more than environment variables: it reads a TOML config, and a
# freshly created cluster has no storage layout assigned -- without a layout
# the server answers requests but refuses to create buckets, which looks like a
# broken install rather than an unconfigured one. This script generates the
# config, boots the server, waits for it to report HEALTHY, assigns the node to
# a layout if it has no role yet, then keeps running in the foreground.

DATA_DIR="/var/lib/garage"
META_DIR="${DATA_DIR}/meta"
DATASTORE_DIR="${DATA_DIR}/data"
CONF="${DATA_DIR}/garage.toml"

mkdir -p "${META_DIR}" "${DATASTORE_DIR}"

# The config is regenerated on every start so that a change to the deploy
# params takes effect, while the node identity and layout live under meta/.
cat > "${CONF}" <<EOF
metadata_dir = "${META_DIR}"
data_dir = "${DATASTORE_DIR}"
db_engine = "lmdb"
replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_secret = "${GARAGE_RPC_SECRET}"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"

[s3_web]
bind_addr = "[::]:3902"
root_domain = ".web.garage.localhost"
index = "index.html"

[admin]
api_bind_addr = "[::]:3903"
admin_token = "${GARAGE_ADMIN_TOKEN}"
EOF

# Start the server in the background first so the layout can be assigned.
garage -c "${CONF}" server &
GARAGE_PID=$!

# If the server dies on its own, keep the container alive so the log is readable.
trap 'kill -TERM "${GARAGE_PID}" 2>/dev/null || true' TERM INT

# Wait for the node to become reachable before asking about its layout.
i=0
while [ "${i}" -lt 120 ]; do
  if garage -c "${CONF}" status >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

# Assign the node a role only when it still has none, so restarts are no-ops.
if garage -c "${CONF}" status 2>/dev/null | grep -q "NO ROLE"; then
  echo "garage: assigning layout to the local node"
  garage -c "${CONF}" status \
    | grep "NO ROLE" \
    | grep -Eo '^[0-9a-f]+' \
    | while read -r node_id; do
        garage -c "${CONF}" layout assign "${node_id}" -z dc1 -c 1G || true
      done
  garage -c "${CONF}" layout apply --version 1 || true
fi

echo "garage: S3 endpoint on :3900, admin API on :3903"
wait "${GARAGE_PID}"
