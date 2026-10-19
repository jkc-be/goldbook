#!/usr/bin/env python3
"""Build an installable Goldbook ZIP for CurseForge and manual installs, and the
release.json that tells WowUp which game flavor the ZIP is for."""
import argparse
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parent
# BigWigs packager flavors by interface prefix, as WowUp reads them from release.json.
FLAVORS = {'11': 'classic', '16': 'forever', '20': 'bcc', '30': 'wrath', '40': 'cata', '50': 'mists'}


def flavor(interface):
    if interface >= 100000:
        return 'mainline'
    if 10000 <= interface < 100000 and str(interface)[:2] in FLAVORS:
        return FLAVORS[str(interface)[:2]]
    raise ValueError(f'No release.json flavor for interface {interface}')


def release_metadata(toc, version):
    interfaces = re.findall(r'^## Interface: ([0-9]+(?:\s*,\s*[0-9]+)*)\s*$', toc, re.MULTILINE)
    if len(interfaces) != 1:
        raise ValueError('Goldbook.toc must contain one valid interface line')
    metadata = [{'flavor': flavor(int(number)), 'interface': int(number)} for number in interfaces[0].split(',')]
    return {'releases': [{'name': 'Goldbook', 'version': version, 'filename': f'Goldbook-{version}.zip',
                          'nolib': False, 'metadata': metadata}]}


def package(output, source=ROOT):
    addon = source / 'Goldbook'
    files = {}
    for path in sorted(addon.rglob('*')):
        relative = path.relative_to(addon)
        if any(part.startswith('.') for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError(f'Addon package cannot contain a symbolic link: {relative}')
        if path.is_file():
            files[relative.as_posix()] = path.read_bytes()
    toc = files['Goldbook.toc'].decode('utf-8')
    versions = re.findall(r'^## Version: ([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)\s*$', toc, re.MULTILINE)
    if len(versions) != 1:
        raise ValueError('Goldbook.toc must contain one valid version')
    for line in toc.splitlines():
        line = line.strip()
        if line and not line.startswith('#') and line.replace('\\', '/') not in files:
            raise ValueError(f'TOC references a missing file: {line}')
    files['LICENSE'] = (source / 'LICENSE').read_bytes()
    destination = output / f'Goldbook-{versions[0]}.zip'
    metadata = release_metadata(toc, versions[0])
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo('Goldbook/' + name)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content)
    (output / 'release.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='Directory for the installable ZIP and release.json')
    print(package(parser.parse_args().output))
