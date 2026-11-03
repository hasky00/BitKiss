#!/usr/bin/env bash
# One-shot setup of the BitKiss VSS server. Run on the server as root:
#   bash setup.sh
# Creates /root/vss only. Does not touch /root/relay-setup or any existing container.
set -euo pipefail

VSS_DIR=/root/vss
mkdir -p "$VSS_DIR"
cd "$VSS_DIR"

# 1. Source code of the reference VSS server (Rust, Apache/MIT).
if [ ! -d src/.git ]; then
  git clone --depth 1 https://github.com/lightningdevkit/vss-server.git src
else
  git -C src pull --ff-only
fi

# 2. Find the Docker network the existing Caddy container is on, so Caddy can reach us by name.
CADDY_CONTAINER=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /^caddy/ {print $1; exit}')
if [ -z "$CADDY_CONTAINER" ]; then
  echo "Could not find a running Caddy container. Is it up?" >&2; exit 1
fi
CADDY_NETWORK=$(docker inspect "$CADDY_CONTAINER" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | grep -v '^bridge$' | head -1)
echo "Caddy container: $CADDY_CONTAINER   network: $CADDY_NETWORK"

# 3. Secrets live in .env (chmod 600), generated once.
if [ ! -f .env ]; then
  echo "VSS_PG_PASSWORD=$(openssl rand -hex 24)" > .env
  chmod 600 .env
fi
grep -q '^CADDY_NETWORK=' .env || echo "CADDY_NETWORK=$CADDY_NETWORK" >> .env

# 4. Build + start. First build compiles Rust in Docker: 5-10 minutes.
docker compose up -d --build

echo
echo "VSS is up on the internal network as vss-server:8080."
echo "Now append this to the Caddyfile (new block, nothing else changed) and reload Caddy:"
echo
cat Caddyfile.snippet
echo
echo "Reload:  docker exec $CADDY_CONTAINER caddy reload --config /etc/caddy/Caddyfile"
