#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <ssh-host>" >&2
  exit 2
fi
host=$1
# Verify approval and branch restrictions before installing any credential.
python3 "$(dirname "${BASH_SOURCE[0]}")/configure-github.py" --check
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
ssh -G "$host" > "$temporary/ssh-config"
hostname=$(awk '$1 == "hostname" {print $2; exit}' "$temporary/ssh-config")
user=$(awk '$1 == "user" {print $2; exit}' "$temporary/ssh-config")
port=$(awk '$1 == "port" {print $2; exit}' "$temporary/ssh-config")
[[ $port == 22 ]] || { echo "The Actions workflow expects SSH port 22" >&2; exit 1; }

ssh -T "$host" 'test -O /opt/goldbook && test -f /opt/goldbook/.env && docker info >/dev/null'
scp -q "$repo/scripts/deploy-ovh.py" "$host:/opt/goldbook/deploy-public.py.new"
ssh -T "$host" 'python3 -' <<'PY'
import ast
from pathlib import Path
import shutil

root = Path('/opt/goldbook')
helper = root / 'deploy-public.py.new'
ast.parse(helper.read_text())
compose = root / 'app/server/compose.yaml'
original = compose.read_text()
old = '    image: goldbook\n'
new = '    image: ${GOLDBOOK_IMAGE:-goldbook}\n'
if original.count(old) == 1:
    backup = compose.with_name('compose.yaml.before-github-actions')
    if not backup.exists():
        shutil.copy2(compose, backup)
    temporary = compose.with_suffix('.yaml.new')
    temporary.write_text(original.replace(old, new))
    temporary.chmod(compose.stat().st_mode & 0o777)
    temporary.replace(compose)
elif original.count(new) != 1:
    raise SystemExit('Expected the Goldbook image setting in compose.yaml')
helper.chmod(0o700)
helper.replace(root / 'deploy-public.py')
PY

# Read the public host key over the administrator's already trusted SSH connection.
printf '%s ' "$hostname" > "$temporary/known_hosts"
ssh -T "$host" 'cat /etc/ssh/ssh_host_ed25519_key.pub' >> "$temporary/known_hosts"
ssh-keygen -q -t ed25519 -N '' -C goldbook-public-github-actions -f "$temporary/key"
printf 'restrict,command="/usr/bin/python3 /opt/goldbook/deploy-public.py" %s\n' \
  "$(cat "$temporary/key.pub")" > "$temporary/authorized_key"
public_key=$(base64 < "$temporary/authorized_key" | tr -d '\n')
ssh -T "$host" "python3 - $public_key" <<'PYTHON'
import base64
from pathlib import Path
import sys

directory = Path.home() / '.ssh'
directory.mkdir(mode=0o700, exist_ok=True)
path = directory / 'authorized_keys'
lines = path.read_text().splitlines() if path.exists() else []
lines = [line for line in lines if not line.split() or line.split()[-1] != 'goldbook-public-github-actions']
lines.append(base64.b64decode(sys.argv[1]).decode().strip())
temporary = path.with_name('authorized_keys.new')
temporary.write_text('\n'.join(lines) + '\n')
temporary.chmod(0o600)
temporary.replace(path)
PYTHON

if ssh -T -F /dev/null -i "$temporary/key" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$temporary/known_hosts" -o ConnectTimeout=15 \
  "$user@$hostname" true > "$temporary/probe" 2>&1; then
  echo "The deployment key unexpectedly allowed an unrestricted command" >&2
  exit 1
fi
grep -Fq "Only 'deploy <run ID> <SHA>'" "$temporary/probe"

gh secret set DEPLOY_HOST --repo jkc-be/goldbook --env production --body "$hostname"
gh secret set DEPLOY_USER --repo jkc-be/goldbook --env production --body "$user"
gh secret set DEPLOY_KNOWN_HOSTS --repo jkc-be/goldbook --env production < "$temporary/known_hosts"
gh secret set DEPLOY_SSH_KEY --repo jkc-be/goldbook --env production < "$temporary/key"
echo "Goldbook's restricted deployment key and protected production environment secrets are configured."
