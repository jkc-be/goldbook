#!/usr/bin/env bash
set -euo pipefail

notarize=${NOTARIZE:-true}
required=(APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID RUNNER_TEMP)
if [[ "$notarize" == true ]]; then
  required+=(APPLE_ID APPLE_PASSWORD)
else
  # Tauri notarizes whenever these are set.
  unset APPLE_ID APPLE_PASSWORD
  echo '::warning::Notarization is off, so Gatekeeper warns on first launch. See https://github.com/jkc-be/goldbook/issues/24.'
fi
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing $name in the protected release-signing environment."
    exit 1
  fi
done
if [[ "${RELEASE_BUILD:-false}" == true && -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  echo '::error::Missing TAURI_SIGNING_PRIVATE_KEY in the protected release-signing environment.'
  exit 1
fi

signing_dir=$(mktemp -d "$RUNNER_TEMP/goldbook-signing.XXXXXX")
keychain_path="$signing_dir/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT
umask 077

printf '%s' "$APPLE_CERTIFICATE" | /usr/bin/base64 --decode > "$signing_dir/certificate.p12"
keychain_password=$(openssl rand -hex 32)
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$signing_dir/certificate.p12" -k "$keychain_path" \
  -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path" "$HOME/Library/Keychains/login.keychain-db"
# Install Apple's intermediate without changing certificate trust settings.
curl --fail --silent --show-error --location \
  https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer \
  -o "$signing_dir/DeveloperIDG2CA.cer"
security import "$signing_dir/DeveloperIDG2CA.cer" -k "$keychain_path"
security find-identity -v -p codesigning "$keychain_path" | \
  grep -F "\"$APPLE_SIGNING_IDENTITY\""
rm "$signing_dir/certificate.p12"
unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD keychain_password

python3 - "$signing_dir/config.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1], 'w') as config:
    json.dump({'bundle': {
        'createUpdaterArtifacts': os.environ.get('RELEASE_BUILD') == 'true',
        'macOS': {'signingIdentity': os.environ['APPLE_SIGNING_IDENTITY']},
    }}, config)
PY
npm run desktop:pack -- --ci --bundles "${BUNDLES:-app,dmg}" --config "$signing_dir/config.json"

app=target/release/bundle/macos/Goldbook.app
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -F "TeamIdentifier=$APPLE_TEAM_ID"
if [[ "$notarize" == true ]]; then
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi
shopt -s nullglob
dmgs=(target/release/bundle/dmg/*.dmg)
if [[ ${#dmgs[@]} -eq 0 ]]; then
  echo '::error::The macOS build produced no DMG.'
  exit 1
fi
for dmg in "${dmgs[@]}"; do
  codesign --verify --strict --verbose=2 "$dmg"
  [[ "$notarize" == true ]] || continue
  # Tauri notarizes the app; submit the signed DMG separately as well.
  xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" \
    --wait --timeout 20m --output-format json > "$signing_dir/notarization.json"
  python3 - "$signing_dir/notarization.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as receipt:
    status = json.load(receipt)['status']
if status != 'Accepted':
    sys.exit(f'DMG notarization failed: {status}')
PY
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
done
