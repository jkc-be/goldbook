#!/usr/bin/env python3
"""Upload the tested release ZIP to Goldbook's WoWInterface project."""
import argparse
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid
import zipfile

API = 'https://api.wowinterface.com/addons/update'


class UploadError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise UploadError('WoWInterface redirected the request; no credentials were forwarded.')


def upload(token, body, content_type):
    request = Request(API, data=body, headers={
        'X-Api-Token': token, 'Content-Type': content_type,
    })
    try:
        with build_opener(NoRedirect).open(request, timeout=60) as response:
            # The API documents 202, but successful uploads have been reported as 200.
            if response.status not in (200, 202):
                raise UploadError('WoWInterface did not accept the update. Check the project before retrying.')
    except HTTPError as error:
        raise UploadError(f'WoWInterface returned HTTP {error.code}. Response details are withheld.') from None
    except (URLError, TimeoutError, OSError, ValueError, HTTPException):
        raise UploadError('No valid WoWInterface response. Check the project before retrying an upload.') from None


def archive_details(archive):
    content = archive.read_bytes()
    try:
        with zipfile.ZipFile(archive) as package:
            toc = package.read('Goldbook/Goldbook.toc').decode('utf-8')
    except (zipfile.BadZipFile, KeyError, UnicodeError):
        raise UploadError('The ZIP must contain Goldbook/Goldbook.toc.') from None
    versions = re.findall(r'^## Version: ([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)\s*$', toc, re.MULTILINE)
    if len(versions) != 1 or archive.name != f'Goldbook-{versions[0]}.zip':
        raise UploadError('The ZIP filename and TOC version must describe one release.')
    return content, versions[0]


def check_receipt(receipt, content, version, project_id):
    expected = {'project_id': project_id, 'version': version,
                'sha256': hashlib.sha256(content).hexdigest()}
    if not isinstance(receipt, dict) or any(receipt.get(key) != value for key, value in expected.items()):
        raise UploadError('The WoWInterface receipt does not match this project, version and ZIP.')
    if type(receipt['project_id']) is not int or receipt.get('status') != 'accepted':
        raise UploadError('The WoWInterface receipt does not record an accepted upload.')


def publish(archive, changelog, receipt_path, token, project_id):
    if type(project_id) is not int or project_id <= 0:
        raise UploadError('Set a valid WoWInterface project ID.')
    content, version = archive_details(archive)
    if receipt_path.exists():
        check_receipt(json.loads(receipt_path.read_text()), content, version, project_id)
        return
    if not token:
        raise UploadError('Set WOWINTERFACE_API_TOKEN in the protected wowinterface environment.')
    boundary = uuid.uuid4().hex
    fields = {'id': str(project_id), 'version': version, 'changelog': changelog}
    # Compatibility is managed on the project page. WoWInterface does not list
    # the Forever client, so do not substitute another game's compatibility.
    body = b''.join((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n'
                     f'\r\n{value}\r\n').encode() for name, value in fields.items())
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="updatefile"; filename="{archive.name}"\r\n'
             'Content-Type: application/zip\r\n\r\n').encode() + content + f'\r\n--{boundary}--\r\n'.encode()
    upload(token, body, f'multipart/form-data; boundary={boundary}')
    receipt = {'project_id': project_id, 'version': version, 'status': 'accepted',
               'sha256': hashlib.sha256(content).hexdigest()}
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--project-id', type=int, required=True)
    parser.add_argument('--changelog', type=Path, default=Path('release-notes.md'))
    parser.add_argument('--receipt', type=Path, default=Path('wowinterface.json'))
    parser.add_argument('--check', action='store_true', help='Verify an existing receipt without network access')
    args = parser.parse_args()
    try:
        if args.project_id <= 0:
            raise UploadError('Set a valid WoWInterface project ID.')
        if args.check:
            content, version = archive_details(args.archive)
            check_receipt(json.loads(args.receipt.read_text()), content, version, args.project_id)
        else:
            publish(args.archive, args.changelog.read_text(), args.receipt,
                    os.environ.get('WOWINTERFACE_API_TOKEN', ''), args.project_id)
    except (UploadError, OSError, ValueError) as error:
        print(str(error) if isinstance(error, UploadError) else 'Could not read or write the release files.', file=sys.stderr)
        return 1
    print(f'WoWInterface accepted: https://www.wowinterface.com/downloads/info{args.project_id}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
