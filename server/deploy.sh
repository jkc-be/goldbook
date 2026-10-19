#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <ssh-host>" >&2
  exit 2
fi
host=$1
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Runs a script under bash on the host, whatever its login shell, with a
# terminal so that sudo can ask for a password.
on_host() {
  ssh -t "$host" "echo $(printf '%s' "$1" | base64 | tr -d '\n') | base64 -d | bash"
}

prepare=$(cat <<'EOF'
set -euo pipefail
if [[ ! -d /opt/goldbook || ! -O /opt/goldbook ]]; then
  sudo install -d -o "$(id -u)" -g "$(id -g)" /opt/goldbook
fi
mkdir -p /opt/goldbook/app /opt/goldbook/data
EOF
)

start=$(cat <<'EOF'
set -euo pipefail
env_file=/opt/goldbook/.env
if [[ ! -e $env_file ]]; then
  bind=127.0.0.1
  if command -v tailscale >/dev/null; then
    bind=$(tailscale ip -4 | head -n 1)
  fi
  # Written aside and renamed, so an interrupted run leaves no half file
  # that later runs would keep.
  umask 077
  printf 'GOLDBOOK_BIND=%s\nGOLDBOOK_DATA=/opt/goldbook/data\nGOLDBOOK_USER=%s\n' \
    "$bind" "$(id -u):$(id -g)" > "$env_file.new"
  mv "$env_file.new" "$env_file"
fi

docker=(docker)
if ! docker info >/dev/null 2>&1; then
  docker=(sudo docker)
fi
# A deploy from this checkout builds a local image instead of using the last
# image pinned by GitHub Actions.
if grep -q '^GOLDBOOK_IMAGE=' "$env_file"; then
  umask 077
  sed '/^GOLDBOOK_IMAGE=/d' "$env_file" > "$env_file.new"
  mv "$env_file.new" "$env_file"
fi
compose=("${docker[@]}" compose -p goldbook --env-file "$env_file" -f /opt/goldbook/app/server/compose.yaml)
public_host=$(sed -n 's/^GOLDBOOK_HOST=//p' "$env_file")
if [[ -n $public_host ]]; then
  compose+=(-f /opt/goldbook/app/server/compose.traefik.yaml)
  if grep -q '^GOLDBOOK_PATH_HOST=.' "$env_file"; then
    compose+=(-f /opt/goldbook/app/server/compose.path.yaml)
  fi
fi
if ! "${compose[@]}" up -d --build --wait --wait-timeout 120; then
  "${compose[@]}" logs --tail 50
  exit 1
fi

echo
if [[ -n $public_host ]]; then
  echo "Goldbook: https://$public_host"
else
  bind=$(sed -n 's/^GOLDBOOK_BIND=//p' "$env_file")
  port=$(sed -n 's/^GOLDBOOK_PORT=//p' "$env_file")
  echo "Goldbook API: http://$bind:${port:-8787}"
fi
EOF
)

on_host "$prepare"
rsync -az --delete --exclude .git --exclude target --exclude node_modules \
  --exclude __pycache__ --exclude .venv --exclude data --exclude fixtures \
  "$repo/" "$host:/opt/goldbook/app/"
on_host "$start"
echo "Upload token: ssh $host cat /opt/goldbook/.env"
