"""Exercise the Wago upload boundary without publishing files or using real secrets."""
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

SPEC = importlib.util.spec_from_file_location('wago', Path(__file__).resolve().parents[1] / 'upload-wago.py')
UPLOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPLOAD)

GAME = json.dumps({'patches': {'forever': ['1.60.0', '1.60.1'], 'retail': ['12.0.1']}}).encode()


class WagoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.receipt = self.root / 'wago.json'

    def archive(self, version='1.2.3', interface='16001'):
        archive = self.root / f'Goldbook-{version}.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr('Goldbook/Goldbook.toc', f'## Interface: {interface}\n## Version: {version}\n')
        return archive

    def test_upload_sends_the_exact_zip_and_records_only_public_metadata(self):
        archive = self.archive()
        with patch.object(UPLOAD, 'request', side_effect=[GAME, b'']) as request:
            UPLOAD.publish(archive, 'Fix the scanner.', self.receipt, 'synthetic-token')
        self.assertEqual(request.call_args_list[0].args, ('/data/game',))
        path, token, body, content_type = request.call_args_list[1].args
        self.assertEqual(path, '/projects/aN0adQ6j/version')
        self.assertEqual(token, 'synthetic-token')
        message = BytesParser(policy=default).parsebytes(f'Content-Type: {content_type}\r\n\r\n'.encode() + body)
        metadata, file = list(message.iter_parts())
        self.assertEqual(json.loads(metadata.get_payload(decode=True)), {
            'label': '1.2.3', 'stability': 'stable', 'changelog': 'Fix the scanner.',
            'supported_forever_patches': ['1.60.1'],
        })
        self.assertEqual(file.get_filename(), 'Goldbook-1.2.3.zip')
        self.assertEqual(file.get_payload(decode=True), archive.read_bytes())
        self.assertEqual(json.loads(self.receipt.read_text()), {
            'project_id': 'aN0adQ6j', 'version': '1.2.3',
            'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        })
        self.assertNotIn('synthetic-token', self.receipt.read_text())
        with patch.object(UPLOAD, 'request') as request:
            UPLOAD.publish(archive, 'Retry.', self.receipt, '')
            request.assert_not_called()

    def test_unlisted_patch_falls_back_to_the_newest_earlier_one(self):
        self.assertEqual(UPLOAD.forever_patch((1, 60, 2), ['1.60.1', '1.60.0', '1.61.0', 'junk']), '1.60.1')
        self.assertEqual(UPLOAD.forever_patch((1, 60, 1), ['1.60.1']), '1.60.1')
        with self.assertRaisesRegex(UPLOAD.UploadError, 'no Forever patch at or before 1.60.1'):
            UPLOAD.forever_patch((1, 60, 1), ['1.61.0'])

    def test_alpha_and_beta_releases_keep_their_stability(self):
        for suffix, expected in [('alpha.1', 'alpha'), ('beta.2', 'beta')]:
            with self.subTest(suffix=suffix), patch.object(UPLOAD, 'request', side_effect=[GAME, b'']) as request:
                UPLOAD.publish(self.archive(f'1.2.3-{suffix}'), '', self.root / f'{suffix}.json', 'synthetic-token')
                self.assertIn(f'"stability": "{expected}"'.encode(), request.call_args.args[2])

    def test_missing_game_versions_never_upload(self):
        for game in [b'not json', b'{}', b'{"patches": {"forever": []}}', b'{"patches": []}']:
            with self.subTest(game=game), patch.object(UPLOAD, 'request', return_value=game) as request:
                with self.assertRaises(UPLOAD.UploadError):
                    UPLOAD.publish(self.archive(), '', self.receipt, 'synthetic-token')
                self.assertEqual(request.call_count, 1)
                self.assertFalse(self.receipt.exists())

    def test_bad_archive_other_flavor_or_missing_secret_never_contacts_wago(self):
        for interface, token in [('invalid', 'synthetic-token'), ('110200', 'synthetic-token'), ('16001', '')]:
            with self.subTest(interface=interface), patch.object(UPLOAD, 'request') as request:
                with self.assertRaises(UPLOAD.UploadError):
                    UPLOAD.publish(self.archive(interface=interface), '', self.receipt, token)
                request.assert_not_called()

    def test_receipt_cannot_skip_a_changed_zip_another_version_or_project(self):
        digest = hashlib.sha256(b'archive').hexdigest()
        for receipt in [
            {'project_id': 'aN0adQ6j', 'version': '1.2.3', 'sha256': 'wrong'},
            {'project_id': 'other', 'version': '1.2.3', 'sha256': digest},
            {'project_id': 'aN0adQ6j', 'version': '1.2.4', 'sha256': digest},
        ]:
            with self.subTest(receipt=receipt), self.assertRaises(UPLOAD.UploadError):
                UPLOAD.check_receipt(receipt, b'archive', '1.2.3')
        UPLOAD.check_receipt({'project_id': 'aN0adQ6j', 'version': '1.2.3', 'sha256': digest}, b'archive', '1.2.3')

    def test_request_uses_a_header_and_never_prints_sensitive_error_details(self):
        failures = [
            HTTPError('https://example.invalid/synthetic-token', 401, 'synthetic-token', {}, io.BytesIO(b'synthetic-token')),
            URLError('synthetic-token'),
        ]
        for failure in failures:
            with self.subTest(failure=type(failure)), patch.object(UPLOAD, 'build_opener') as opener:
                opener.return_value.open.side_effect = failure
                with self.assertRaises(UPLOAD.UploadError) as result:
                    UPLOAD.request('/projects/aN0adQ6j/version', 'synthetic-token', b'')
                self.assertNotIn('synthetic-token', str(result.exception))
                request = opener.return_value.open.call_args.args[0]
                self.assertEqual(request.full_url, 'https://addons.wago.io/api/projects/aN0adQ6j/version')
                self.assertEqual(request.get_header('Authorization'), 'Bearer synthetic-token')

    def test_game_versions_are_read_without_the_token(self):
        with patch.object(UPLOAD, 'build_opener') as opener:
            opener.return_value.open.return_value.__enter__.return_value.read.return_value = GAME
            self.assertEqual(UPLOAD.request('/data/game'), GAME)
            self.assertIsNone(opener.return_value.open.call_args.args[0].get_header('Authorization'))

    def test_redirects_do_not_forward_credentials(self):
        with self.assertRaisesRegex(UPLOAD.UploadError, 'no credentials were forwarded'):
            UPLOAD.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.invalid/')

    def test_failed_upload_does_not_create_a_receipt(self):
        with patch.object(UPLOAD, 'request', side_effect=[GAME, UPLOAD.UploadError('Wago returned HTTP 403.')]):
            with self.assertRaisesRegex(UPLOAD.UploadError, 'HTTP 403'):
                UPLOAD.publish(self.archive(), '', self.receipt, 'synthetic-token')
        self.assertFalse(self.receipt.exists())


if __name__ == '__main__':
    unittest.main()
