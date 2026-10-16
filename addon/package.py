#!/usr/bin/env python3
"""Build an installable Goldbook ZIP for CurseForge and manual installs."""
import argparse
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parent


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
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f'Goldbook-{versions[0]}.zip'
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo('Goldbook/' + name)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='Directory for the installable ZIP')
    print(package(parser.parse_args().output))
