#!/usr/bin/env python3
"""Upload the tested release ZIP to Goldbook's Wago Addons project."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid
import zipfile

API = 'https://addons.wago.io/api'
PROJECT_ID = 'aN0adQ6j'


class UploadError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise UploadError('Wago redirected the request; no credentials were forwarded.')


def request(path, token=None, data=None, content_type=None):
    """The response body of a 2xx reply. Wago's upload reply is not documented, so
    callers that only need success ignore it."""
    headers = {'Accept': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    if content_type:
        headers['Content-Type'] = content_type
    try:
        with build_opener(NoRedirect).open(Request(API + path, data=data, headers=headers), timeout=60) as response:
            return response.read()
    except HTTPError as error:
        raise UploadError(f'Wago returned HTTP {error.code}. Response details are withheld.') from None
    except (URLError, TimeoutError, OSError):
        raise UploadError('No valid Wago response. Check the project versions before retrying an upload.') from None


def archive_details(archive):
    content = archive.read_bytes()
    try:
        with zipfile.ZipFile(archive) as package:
            toc = package.read('Goldbook/Goldbook.toc').decode('utf-8')
    except (zipfile.BadZipFile, KeyError, UnicodeError):
        raise UploadError('The ZIP must contain Goldbook/Goldbook.toc.') from None
    version = re.findall(r'^## Version: ([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)\s*$', toc, re.MULTILINE)
    interfaces = re.findall(r'^## Interface: ([0-9]+(?:\s*,\s*[0-9]+)*)\s*$', toc, re.MULTILINE)
    if len(version) != 1 or len(interfaces) != 1 or archive.name != f'Goldbook-{version[0]}.zip':
        raise UploadError('The ZIP filename, TOC version and interface metadata must describe one release.')
    patches = []
    for interface in interfaces[0].split(','):
        number = int(interface)
        if number // 1000 != 16:
            raise UploadError(f'Only WoW Forever interfaces (16xxx) are uploaded to Wago, not {number}.')
        patches.append((number // 10000, number // 100 % 100, number % 100))
    return content, version[0], patches


def forever_patch(wanted, known):
    """The packager's rule: the exact patch, else the newest one before it."""
    parsed = {}
    for name in known:
        if isinstance(name, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', name):
            parsed[tuple(int(part) for part in name.split('.'))] = name
    candidates = [patch for patch in parsed if patch <= wanted]
    if not candidates:
        raise UploadError(f'Wago lists no Forever patch at or before {".".join(map(str, wanted))}.')
    return parsed[max(candidates)]


def check_receipt(receipt, content, version):
    expected = {'project_id': PROJECT_ID, 'version': version, 'sha256': hashlib.sha256(content).hexdigest()}
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise UploadError('The Wago receipt does not match this project and ZIP.')


def publish(archive, changelog, receipt_path, token):
    content, version, wanted = archive_details(archive)
    if receipt_path.exists():
        return check_receipt(json.loads(receipt_path.read_text()), content, version)
    if not token:
        raise UploadError('Set WAGO_API_TOKEN in the protected wago environment.')
    try:
        game = json.loads(request('/data/game'))
    except ValueError:
        raise UploadError('Wago returned an invalid game version list.') from None
    listing = game.get('patches') if isinstance(game, dict) else None
    known = listing.get('forever') if isinstance(listing, dict) else None
    if not isinstance(known, list):
        raise UploadError('Wago returned an invalid game version list.')
    patches = sorted({forever_patch(patch, known) for patch in wanted})
    stability = 'alpha' if 'alpha' in version.lower() else 'beta' if 'beta' in version.lower() else 'stable'
    metadata = {'label': version, 'stability': stability, 'changelog': changelog,
                'supported_forever_patches': patches}
    boundary = uuid.uuid4().hex
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n'
            f'Content-Type: application/json\r\n\r\n{json.dumps(metadata)}\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{archive.name}"\r\n'
            'Content-Type: application/zip\r\n\r\n').encode() + content + f'\r\n--{boundary}--\r\n'.encode()
    request(f'/projects/{PROJECT_ID}/version', token, body, f'multipart/form-data; boundary={boundary}')
    receipt = {'project_id': PROJECT_ID, 'version': version, 'sha256': hashlib.sha256(content).hexdigest()}
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--changelog', type=Path, default=Path('release-notes.md'))
    parser.add_argument('--receipt', type=Path, default=Path('wago.json'))
    parser.add_argument('--check', action='store_true', help='Verify an existing receipt without network access')
    args = parser.parse_args()
    try:
        if args.check:
            _, version, _ = archive_details(args.archive)
            check_receipt(json.loads(args.receipt.read_text()), args.archive.read_bytes(), version)
        else:
            publish(args.archive, args.changelog.read_text(), args.receipt, os.environ.get('WAGO_API_TOKEN', ''))
    except (UploadError, OSError, ValueError) as error:
        print(str(error) if isinstance(error, UploadError) else 'Could not read or write the release files.', file=sys.stderr)
        return 1
    print(f'https://addons.wago.io/addons/{PROJECT_ID}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
