#!/usr/bin/env python3
"""Package signed client installers or a signed addon for the Goldbook update feed."""
import argparse
import base64
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://app.jkc-be.com/goldbook/updates'


def addon(output):
    files = {p.name: p.read_text() for p in sorted((ROOT / 'addon/Goldbook').iterdir())
             if p.is_file() and (p.suffix == '.lua' or p.name == 'Goldbook.toc')}
    version = next(line.removeprefix('## Version: ').strip() for line in files['Goldbook.toc'].splitlines()
                   if line.startswith('## Version: '))
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    sequence = int(subprocess.check_output(['git', 'show', '-s', '--format=%ct', 'HEAD'], cwd=ROOT))
    payload = output / 'addon-payload.json'
    payload.write_text(json.dumps(dict(version=version, sequence=sequence, revision=revision, files=files), separators=(',', ':')))
    subprocess.run(['npx', 'tauri', 'signer', 'sign', str(payload)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    envelope = {'payload': base64.b64encode(payload.read_bytes()).decode(),
                'signature': payload.with_suffix('.json.sig').read_text().strip()}
    (output / 'addon.json').write_text(json.dumps(envelope, separators=(',', ':')))
    payload.unlink()
    payload.with_suffix('.json.sig').unlink()


def client(output, artifacts):
    version = json.loads((ROOT / 'desktop/src-tauri/tauri.conf.json').read_text())['version']
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    folder = output / revision
    folder.mkdir()
    platforms = {}
    for signature in sorted(artifacts.rglob('*.sig')):
        package = signature.with_suffix('')
        name = package.name
        if name.endswith('.app.tar.gz'):
            target = 'darwin-aarch64'
        elif name.endswith('.exe'):
            target = 'windows-x86_64'
        elif name.endswith('.deb'):
            target = 'linux-x86_64-deb'
        elif name.endswith('.rpm'):
            target = 'linux-x86_64-rpm'
        else:
            continue
        if target in platforms:
            raise ValueError('Duplicate updater target ' + target)
        destination = folder / (target + '-' + name)
        shutil.copyfile(package, destination)
        platforms[target] = {'url': f'{BASE}/{revision}/{destination.name}', 'signature': signature.read_text().strip()}
    expected = {'darwin-aarch64', 'windows-x86_64', 'linux-x86_64-deb', 'linux-x86_64-rpm'}
    if platforms.keys() != expected:
        raise ValueError(f'Missing signed client installers: {expected - platforms.keys()}')
    (output / 'latest.json').write_text(json.dumps({'version': version, 'notes': 'Goldbook client update', 'platforms': platforms}, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['addon', 'client'])
    parser.add_argument('output', type=Path)
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.kind == 'addon':
        addon(args.output)
    else:
        client(args.output, args.artifacts)


if __name__ == '__main__':
    main()
