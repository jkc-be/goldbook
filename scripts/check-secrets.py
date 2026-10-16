#!/usr/bin/env python3
"""Scan committed history with a checksum-pinned Gitleaks binary."""
import hashlib
import io
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '8.30.1'
BUILDS = {
    ('Darwin', 'arm64'): ('darwin_arm64', 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5'),
    ('Linux', 'x86_64'): ('linux_x64', '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'),
}


def main():
    build, checksum = BUILDS[(platform.system(), platform.machine())]
    url = f'https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{build}.tar.gz'
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != checksum:
        raise RuntimeError('Gitleaks archive checksum mismatch')
    with tempfile.TemporaryDirectory(prefix='goldbook-secret-scan-') as temporary:
        with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
            bundle.extractall(temporary, members=[bundle.getmember('gitleaks')], filter='data')
        subprocess.run([str(Path(temporary) / 'gitleaks'), 'git', str(ROOT),
                        '--redact=100', '--no-banner', '--log-opts=--all',
                        '--config', str(ROOT / '.gitleaks.toml')], check=True)


if __name__ == '__main__':
    main()
