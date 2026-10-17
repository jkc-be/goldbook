"""Exercise the upload boundary without publishing files or using real secrets."""
from email.parser import BytesParser
from email.policy import default
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
import zipfile

SPEC = importlib.util.spec_from_file_location('curseforge', Path(__file__).resolve().parents[1] / 'upload-curseforge.py')
UPLOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPLOAD)


class CurseForgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.receipt = self.root / 'curseforge.json'

    def archive(self, version='1.2.3', interface='16001'):
        archive = self.root / f'Goldbook-{version}.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr('Goldbook/Goldbook.toc', f'## Interface: {interface}\n## Version: {version}\n')
        return archive

    def test_upload_sends_the_exact_zip_and_records_only_public_metadata(self):
        archive = self.archive()
        with patch.object(UPLOAD, 'request_json', side_effect=[
            [{'id': 42, 'name': '1.60.1'}, {'id': 43, 'name': '1.15.9'}], {'id': 12345},
        ]) as request:
            self.assertEqual(UPLOAD.publish(archive, 'Fix the scanner.', self.receipt, 'synthetic-token'), 12345)
        self.assertEqual(request.call_args_list[0].args, ('/game/versions', 'synthetic-token'))
        path, token, body, content_type = request.call_args_list[1].args
        self.assertEqual(path, '/projects/1747971/upload-file')
        self.assertEqual(token, 'synthetic-token')
        message = BytesParser(policy=default).parsebytes(f'Content-Type: {content_type}\r\n\r\n'.encode() + body)
        metadata, file = list(message.iter_parts())
        self.assertEqual(json.loads(metadata.get_payload(decode=True)), {
            'changelog': 'Fix the scanner.', 'changelogType': 'markdown',
            'displayName': 'Goldbook 1.2.3', 'gameVersions': [42], 'releaseType': 'release',
        })
        self.assertEqual(file.get_filename(), 'Goldbook-1.2.3.zip')
        self.assertEqual(file.get_payload(decode=True), archive.read_bytes())
        self.assertEqual(json.loads(self.receipt.read_text()), {
            'project_id': 1747971, 'file_id': 12345, 'version': '1.2.3',
            'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        })
        self.assertNotIn('synthetic-token', self.receipt.read_text())
        with patch.object(UPLOAD, 'request_json') as request:
            self.assertEqual(UPLOAD.publish(archive, 'Retry.', self.receipt, ''), 12345)
            request.assert_not_called()

    def test_alpha_and_beta_releases_keep_their_release_type(self):
        for suffix, expected in [('alpha.1', 'alpha'), ('beta.2', 'beta')]:
            with self.subTest(suffix=suffix), patch.object(UPLOAD, 'request_json', side_effect=[
                [{'id': 42, 'name': '1.60.1'}], {'id': 12345},
            ]) as request:
                receipt = self.root / f'{suffix}.json'
                UPLOAD.publish(self.archive(f'1.2.3-{suffix}'), '', receipt, 'synthetic-token')
                body = request.call_args.args[2]
                self.assertIn(f'"releaseType": "{expected}"'.encode(), body)

    def test_missing_or_ambiguous_game_version_never_uploads(self):
        for versions in [[], [{'id': 1, 'name': '1.60.1'}, {'id': 2, 'name': '1.60.1'}]]:
            with self.subTest(versions=versions), patch.object(UPLOAD, 'request_json', return_value=versions) as request:
                with self.assertRaisesRegex(UPLOAD.UploadError, 'Expected one CurseForge game version'):
                    UPLOAD.publish(self.archive(), '', self.receipt, 'synthetic-token')
                self.assertEqual(request.call_count, 1)
                self.assertFalse(self.receipt.exists())

    def test_bad_archive_or_missing_secret_never_contacts_curseforge(self):
        for interface, token in [('invalid', 'synthetic-token'), ('16001', '')]:
            with self.subTest(interface=interface), patch.object(UPLOAD, 'request_json') as request:
                with self.assertRaises(UPLOAD.UploadError):
                    UPLOAD.publish(self.archive(interface=interface), '', self.receipt, token)
                request.assert_not_called()

    def test_receipt_cannot_skip_a_changed_zip_or_wrong_project(self):
        for receipt in [
            {'project_id': 1747971, 'file_id': 12345, 'sha256': 'wrong'},
            {'project_id': 7, 'file_id': 12345, 'sha256': hashlib.sha256(b'archive').hexdigest()},
            {'project_id': 1747971, 'file_id': True, 'sha256': hashlib.sha256(b'archive').hexdigest()},
        ]:
            with self.subTest(receipt=receipt), self.assertRaises(UPLOAD.UploadError):
                UPLOAD.check_receipt(receipt, b'archive')

    def test_request_uses_a_header_and_never_prints_sensitive_error_details(self):
        failures = [
            HTTPError('https://example.invalid/synthetic-token', 401, 'synthetic-token', {}, io.BytesIO(b'synthetic-token')),
            URLError('synthetic-token'),
        ]
        for failure in failures:
            with self.subTest(failure=type(failure)), patch.object(UPLOAD, 'build_opener') as opener:
                opener.return_value.open.side_effect = failure
                with self.assertRaises(UPLOAD.UploadError) as result:
                    UPLOAD.request_json('/game/versions', 'synthetic-token')
                self.assertNotIn('synthetic-token', str(result.exception))
                opener.return_value.open.assert_called_once()
                request = opener.return_value.open.call_args.args[0]
                self.assertEqual(request.full_url, 'https://wow.curseforge.com/api/game/versions')
                self.assertEqual(request.get_header('X-api-token'), 'synthetic-token')

    def test_redirects_do_not_forward_credentials(self):
        with self.assertRaisesRegex(UPLOAD.UploadError, 'no credentials were forwarded'):
            UPLOAD.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.invalid/')

    def test_invalid_upload_response_does_not_create_a_receipt(self):
        with patch.object(UPLOAD, 'request_json', side_effect=[[{'id': 42, 'name': '1.60.1'}], {'id': True}]):
            with self.assertRaisesRegex(UPLOAD.UploadError, 'no valid file ID'):
                UPLOAD.publish(self.archive(), '', self.receipt, 'synthetic-token')
        self.assertFalse(self.receipt.exists())


if __name__ == '__main__':
    unittest.main()
