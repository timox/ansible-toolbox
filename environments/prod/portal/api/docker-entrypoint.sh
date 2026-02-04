#!/bin/sh
set -e

# Ensure the data directory exists and is writable by the node user
mkdir -p /data

# Attempt to update ownership so the unprivileged runtime user can persist data
if chown -R node:node /data 2>/dev/null; then
  chmod 775 /data || true
  echo "[portal-api] Successfully adjusted /data ownership to node:node"
else
  echo "[portal-api] ERROR: Unable to adjust ownership of /data" >&2
  echo "[portal-api] You need to run on the host: sudo mkdir -p /data/portal && sudo chmod 777 /data/portal" >&2
  echo "[portal-api] Or run the setup script: sudo ./setup-data-dirs.sh" >&2
fi

# Test if we can write to /data
if ! su-exec node touch /data/.write-test 2>/dev/null; then
  echo "[portal-api] ERROR: Cannot write to /data directory" >&2
  echo "[portal-api] Current permissions:" >&2
  ls -ld /data >&2
  echo "[portal-api] Run on host: sudo chmod 777 /data/portal" >&2
  exit 1
fi

rm -f /data/.write-test
echo "[portal-api] Write permissions verified on /data"

# Add node user to docker group if docker socket exists
if [ -S /var/run/docker.sock ]; then
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
  echo "[portal-api] Docker socket found with GID: $DOCKER_GID"

  # Create docker group with the correct GID if it doesn't exist
  if ! getent group $DOCKER_GID >/dev/null 2>&1; then
    addgroup -g $DOCKER_GID docker 2>/dev/null || echo "[portal-api] Group $DOCKER_GID already exists"
  fi

  # Add node user to docker group
  addgroup node $(getent group $DOCKER_GID | cut -d: -f1) 2>/dev/null || echo "[portal-api] User node already in docker group"
  echo "[portal-api] User node added to docker group"
else
  echo "[portal-api] WARNING: Docker socket not found at /var/run/docker.sock"
fi

exec su-exec node "$@"
