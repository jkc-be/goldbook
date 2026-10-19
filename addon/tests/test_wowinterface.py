"""Verify publishing and retry behavior without real tokens or uploads."""
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

SPEC = importlib.util.spec_from_file_location('wowinterface', Path(__file__).resolve().parents[1] / 'upload-wowinterface.py')
UPLOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPLOAD)


class WoWInterfaceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.receipt = self.root / 'wowinterface.json'
        self.archive = self.root / 'Goldbook-1.2.3.zip'
        with zipfile.ZipFile(self.archive, 'w') as package:
            package.writestr('Goldbook/Goldbook.toc', '## Interface: 16001\n## Version: 1.2.3\n')

    def test_upload_preserves_the_zip_and_compatibility_and_retry_sends_nothing(self):
        with patch.object(UPLOAD, 'build_opener') as opener:
            opener.return_value.open.return_value.__enter__.return_value.status = 202
            UPLOAD.publish(self.archive, 'Fix bag tracking.', self.receipt, 'synthetic-token', 12345)
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.full_url, 'https://api.wowinterface.com/addons/update')
        self.assertEqual(request.get_header('X-api-token'), 'synthetic-token')
        content_type = request.get_header('Content-type')
        message = BytesParser(policy=default).parsebytes(f'Content-Type: {content_type}\r\n\r\n'.encode() + request.data)
        fields = {part.get_param('name', header='content-disposition'): part for part in message.iter_parts()}
        self.assertEqual(set(fields), {'id', 'version', 'changelog', 'updatefile'})
        self.assertEqual(fields['id'].get_payload(decode=True), b'12345')
        self.assertEqual(fields['version'].get_payload(decode=True), b'1.2.3')
        self.assertEqual(fields['changelog'].get_payload(decode=True), b'Fix bag tracking.')
        self.assertEqual(fields['updatefile'].get_filename(), 'Goldbook-1.2.3.zip')
        self.assertEqual(fields['updatefile'].get_payload(decode=True), self.archive.read_bytes())
        self.assertEqual(json.loads(self.receipt.read_text()), {
            'project_id': 12345, 'version': '1.2.3', 'status': 'accepted',
            'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest(),
        })
        with patch.object(UPLOAD, 'build_opener') as opener:
            UPLOAD.publish(self.archive, 'Retry.', self.receipt, '', 12345)
            opener.assert_not_called()

    def test_invalid_receipts_never_suppress_an_upload_silently(self):
        receipt = {'project_id': 12345, 'version': '1.2.3', 'status': 'accepted',
                   'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        for changed in [{'project_id': 42}, {'version': '1.2.4'}, {'sha256': 'wrong'}, {'status': 'pending'}]:
            with self.subTest(changed=changed), patch.object(UPLOAD, 'build_opener') as opener:
                self.receipt.write_text(json.dumps(receipt | changed))
                with self.assertRaises(UPLOAD.UploadError):
                    UPLOAD.publish(self.archive, '', self.receipt, 'synthetic-token', 12345)
                opener.assert_not_called()

    def test_missing_configuration_or_bad_archive_never_contacts_the_service(self):
        for token, project in [('', 12345), ('synthetic-token', 0), ('synthetic-token', True)]:
            with self.subTest(project=project, token=bool(token)), patch.object(UPLOAD, 'build_opener') as opener:
                with self.assertRaises(UPLOAD.UploadError):
                    UPLOAD.publish(self.archive, '', self.receipt, token, project)
                opener.assert_not_called()
        self.archive.write_bytes(b'not a zip')
        with patch.object(UPLOAD, 'build_opener') as opener:
            with self.assertRaises(UPLOAD.UploadError):
                UPLOAD.publish(self.archive, '', self.receipt, 'synthetic-token', 12345)
            opener.assert_not_called()

    def test_filename_must_match_the_toc_version(self):
        renamed = self.archive.rename(self.root / 'Goldbook-1.2.4.zip')
        with self.assertRaises(UPLOAD.UploadError):
            UPLOAD.publish(renamed, '', self.receipt, 'synthetic-token', 12345)

    def test_failed_or_ambiguous_responses_never_create_a_receipt_or_retry(self):
        for status in [200, 204, 302]:
            with self.subTest(status=status), patch.object(UPLOAD, 'build_opener') as opener:
                opener.return_value.open.return_value.__enter__.return_value.status = status
                with self.assertRaises(UPLOAD.UploadError):
                    UPLOAD.publish(self.archive, '', self.receipt, 'synthetic-token', 12345)
                self.assertFalse(self.receipt.exists())
                opener.return_value.open.assert_called_once()
        failures = [
            HTTPError('https://example.invalid/synthetic-token', 401, 'synthetic-token', {}, io.BytesIO(b'synthetic-token')),
            URLError('synthetic-token'), TimeoutError('synthetic-token'),
        ]
        for failure in failures:
            with self.subTest(failure=type(failure)), patch.object(UPLOAD, 'build_opener') as opener:
                opener.return_value.open.side_effect = failure
                with self.assertRaises(UPLOAD.UploadError) as result:
                    UPLOAD.publish(self.archive, '', self.receipt, 'synthetic-token', 12345)
                self.assertNotIn('synthetic-token', str(result.exception))
                self.assertFalse(self.receipt.exists())
                opener.return_value.open.assert_called_once()

    def test_redirects_do_not_forward_credentials(self):
        with self.assertRaisesRegex(UPLOAD.UploadError, 'no credentials were forwarded'):
            UPLOAD.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.invalid/')


if __name__ == '__main__':
    unittest.main()
