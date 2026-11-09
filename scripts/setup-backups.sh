#!/usr/bin/env bash
set -euo pipefail

# Installs the hourly database backup to OVH Object Storage on <ssh-host>: age
# and zstd, /opt/goldbook/backup-ovh.py, its settings in
# /opt/goldbook/backup.env and the goldbook-backup systemd timer. Then runs one
# backup. It asks for the bucket, its keys and the age public key only while the
# host has no backup.env, so a rerun updates the script and the units and keeps
# the settings. The secret key goes to the host over SSH's standard input, never
# on a command line.
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

ssh -T "$host" 'test -O /opt/goldbook && test -f /opt/goldbook/data/goldbook.sqlite'
if ! ssh -T "$host" 'test -s /opt/goldbook/backup.env'; then
  read -rp "S3 endpoint [https://s3.gra.io.cloud.ovh.net]: " endpoint
  read -rp "S3 region [gra]: " region
  read -rp "S3 bucket: " bucket
  read -rp "S3 access key: " access_key
  read -rsp "S3 secret key: " secret_key
  echo
  read -rp "age public key: " recipient
  if [[ -z $bucket || -z $access_key || -z $secret_key || $recipient != age1* ]]; then
    echo "The bucket, both keys and an age public key (age1...) are required." >&2
    exit 1
  fi
  printf 'S3_ENDPOINT=%s\nS3_REGION=%s\nS3_BUCKET=%s\nS3_ACCESS_KEY=%s\nS3_SECRET_KEY=%s\nAGE_RECIPIENT=%s\n' \
    "${endpoint:-https://s3.gra.io.cloud.ovh.net}" "${region:-gra}" "$bucket" "$access_key" "$secret_key" \
    "$recipient" |
    ssh -T "$host" 'umask 077 && cat > /opt/goldbook/backup.env.new && mv /opt/goldbook/backup.env.new /opt/goldbook/backup.env'
fi

scp -q "$repo/scripts/backup-ovh.py" "$host:/opt/goldbook/backup-ovh.py.new"
ssh -T "$host" 'chmod 700 /opt/goldbook/backup-ovh.py.new && mv /opt/goldbook/backup-ovh.py.new /opt/goldbook/backup-ovh.py'

install=$(cat <<'EOF'
set -euo pipefail
user=$(id -un)
sudo dnf install -y -q age zstd
sudo tee /etc/systemd/system/goldbook-backup.service > /dev/null <<UNIT
[Unit]
Description=Back up the Goldbook database to OVH Object Storage
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$user
ExecStart=/usr/bin/python3 /opt/goldbook/backup-ovh.py backup
PrivateTmp=yes
Nice=10
IOSchedulingClass=idle
UNIT
sudo tee /etc/systemd/system/goldbook-backup.timer > /dev/null <<'UNIT'
[Unit]
Description=Back up the Goldbook database to OVH Object Storage every hour

[Timer]
OnCalendar=*-*-* *:05:00
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now goldbook-backup.timer
if ! sudo systemctl start goldbook-backup.service; then
  journalctl -u goldbook-backup.service -n 20 --no-pager -o cat
  exit 1
fi
journalctl _SYSTEMD_UNIT=goldbook-backup.service -n 1 --no-pager -o cat
systemctl list-timers goldbook-backup.timer --no-pager
EOF
)
on_host "$install"
echo "Backups in the bucket: ssh $host python3 /opt/goldbook/backup-ovh.py list"
