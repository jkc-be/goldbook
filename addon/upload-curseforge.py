#!/usr/bin/env python3
"""Upload the tested release ZIP to Goldbook's CurseForge project."""
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

API = 'https://wow.curseforge.com/api'
PROJECT_ID = 1747971


class UploadError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise UploadError('CurseForge redirected the request; no credentials were forwarded.')


def request_json(path, token, data=None, content_type=None):
    headers = {'X-Api-Token': token, 'Accept': 'application/json'}
    if content_type:
        headers['Content-Type'] = content_type
    request = Request(API + path, data=data, headers=headers)
    try:
        with build_opener(NoRedirect).open(request, timeout=60) as response:
            return json.load(response)
    except HTTPError as error:
        raise UploadError(f'CurseForge returned HTTP {error.code}. Response details are withheld.') from None
    except (URLError, TimeoutError, OSError, ValueError):
        raise UploadError('No valid CurseForge response. Check the project files before retrying an upload.') from None


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
    game_versions = []
    for interface in interfaces[0].split(','):
        number = int(interface)
        game_versions.append(f'{number // 10000}.{number // 100 % 100}.{number % 100}')
    return content, version[0], game_versions


def check_receipt(receipt, content):
    expected = {'project_id': PROJECT_ID, 'sha256': hashlib.sha256(content).hexdigest()}
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise UploadError('The CurseForge receipt does not match this project and ZIP.')
    file_id = receipt.get('file_id')
    if type(file_id) is not int or file_id <= 0:
        raise UploadError('The CurseForge receipt has no valid file ID.')
    return file_id


def publish(archive, changelog, receipt_path, token):
    content, version, game_names = archive_details(archive)
    if receipt_path.exists():
        return check_receipt(json.loads(receipt_path.read_text()), content)
    if not token:
        raise UploadError('Set CURSEFORGE_API_TOKEN in the protected curseforge environment.')
    versions = request_json('/game/versions', token)
    if not isinstance(versions, list):
        raise UploadError('CurseForge returned an invalid game version list.')
    game_ids = []
    for name in game_names:
        matches = [entry['id'] for entry in versions if isinstance(entry, dict)
                   and entry.get('name') == name and type(entry.get('id')) is int]
        if len(matches) != 1:
            raise UploadError(f'Expected one CurseForge game version for {name}; found {len(matches)}.')
        game_ids.append(matches[0])
    release_type = 'alpha' if 'alpha' in version.lower() else 'beta' if 'beta' in version.lower() else 'release'
    metadata = {'changelog': changelog, 'changelogType': 'markdown',
                'displayName': f'Goldbook {version}', 'gameVersions': game_ids, 'releaseType': release_type}
    boundary = uuid.uuid4().hex
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\n'
            f'Content-Type: application/json\r\n\r\n{json.dumps(metadata)}\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{archive.name}"\r\n'
            'Content-Type: application/zip\r\n\r\n').encode() + content + f'\r\n--{boundary}--\r\n'.encode()
    result = request_json(f'/projects/{PROJECT_ID}/upload-file', token, body,
                          f'multipart/form-data; boundary={boundary}')
    if not isinstance(result, dict) or type(result.get('id')) is not int or result['id'] <= 0:
        raise UploadError('CurseForge returned no valid file ID. Check the project files before retrying.')
    receipt = {'project_id': PROJECT_ID, 'file_id': result['id'], 'version': version,
               'sha256': hashlib.sha256(content).hexdigest()}
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    return result['id']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--changelog', type=Path, default=Path('release-notes.md'))
    parser.add_argument('--receipt', type=Path, default=Path('curseforge.json'))
    parser.add_argument('--check', action='store_true', help='Verify an existing receipt without network access')
    args = parser.parse_args()
    try:
        if args.check:
            file_id = check_receipt(json.loads(args.receipt.read_text()), args.archive.read_bytes())
        else:
            file_id = publish(args.archive, args.changelog.read_text(), args.receipt,
                              os.environ.get('CURSEFORGE_API_TOKEN', ''))
    except (UploadError, OSError, ValueError) as error:
        print(str(error) if isinstance(error, UploadError) else 'Could not read or write the release files.', file=sys.stderr)
        return 1
    print(f'https://www.curseforge.com/wow/addons/goldbook/files/{file_id}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
