"""Exercise update-feed publication through the restricted SSH helper."""
import importlib.util
import io
import fcntl
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location('update_deployment', Path(__file__).parents[1] / 'deploy-ovh.py')
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)
REVISION = 'a' * 40


class PublishUpdates(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.patch = mock.patch.object(DEPLOY, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.run = dict(head_sha=REVISION, head_branch='main', name='Release Goldbook client from main',
                        path='.github/workflows/release-desktop.yml', event='workflow_dispatch',
                        repository={'full_name': 'jkc-be/goldbook'},
                        head_repository={'full_name': 'jkc-be/goldbook'},
                        actor={'id': 156444954}, triggering_actor={'id': 156444954})
        self.manifest = {'version': '0.1.3', 'platforms': {'darwin-aarch64': {
            'url': 'https://app.jkc-be.com/goldbook/updates/' + REVISION + '/client.tar.gz', 'signature': 'signed'}}}
        self.files = {'latest.json': json.dumps(self.manifest), REVISION + '/client.tar.gz': 'signed package'}

    def response(self, request, **_):
        if request.full_url.endswith('/actions/runs/123'):
            value = json.dumps(self.run).encode()
        elif request.full_url.endswith('/actions/runs/123/artifacts'):
            value = json.dumps({'artifacts': [{'id': 456, 'name': 'Goldbook-update-feed', 'expired': False}]}).encode()
        else:
            self.assertTrue(request.full_url.endswith('/actions/artifacts/456/zip'))
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, 'w') as output:
                for name, content in self.files.items():
                    output.writestr(name, content)
            value = archive.getvalue()
        return io.BytesIO(value)

    def publish(self):
        with mock.patch.object(DEPLOY.OPENER, 'open', side_effect=self.response):
            DEPLOY.publish_updates('123', REVISION, 'test-token')

    def test_publishes_complete_feed_and_retries_without_changing_immutable_packages(self):
        self.publish()
        self.publish()
        destination = self.root / 'data/updates'
        self.assertEqual(json.loads((destination / 'latest.json').read_text()), self.manifest)
        self.assertEqual((destination / REVISION / 'client.tar.gz').read_text(), 'signed package')
        self.files[REVISION + '/client.tar.gz'] = 'different'
        with self.assertRaisesRegex(RuntimeError, 'different update packages'):
            self.publish()
        self.assertEqual((destination / REVISION / 'client.tar.gz').read_text(), 'signed package')

    def test_rejects_wrong_revision_branch_workflow_path_and_missing_package(self):
        for field, value in [('head_sha', 'b' * 40), ('head_branch', 'other'), ('path', '.github/workflows/other.yml'),
                             ('repository', {'full_name': 'other/goldbook'}),
                             ('head_repository', {'full_name': 'other/goldbook'}),
                             ('actor', {'id': 123}), ('triggering_actor', {'id': 123}),
                             ('event', 'pull_request'), ('event', 'pull_request_target')]:
            original = self.run[field]
            self.run[field] = value
            with self.assertRaisesRegex(RuntimeError, 'Only a maintainer Goldbook workflow'):
                self.publish()
            self.run[field] = original
        self.files['../outside'] = 'bad'
        with self.assertRaisesRegex(RuntimeError, 'Invalid update artifact path'):
            self.publish()
        self.files.pop('../outside')
        self.files.pop(REVISION + '/client.tar.gz')
        with self.assertRaisesRegex(RuntimeError, 'Update package is missing'):
            self.publish()
        self.assertFalse((self.root / 'data/updates/latest.json').exists())

    def test_a_server_deployment_does_not_block_update_publication(self):
        with (self.root / '.deploy.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with mock.patch.dict(DEPLOY.os.environ, SSH_ORIGINAL_COMMAND='publish 123 ' + REVISION), \
                 mock.patch.object(DEPLOY.sys, 'stdin', io.StringIO('test-token')), \
                 mock.patch.object(DEPLOY, 'publish_updates') as publish:
                DEPLOY.main()
                publish.assert_called_once_with('123', REVISION, 'test-token')

    def test_addon_feed_uses_one_atomic_signed_envelope(self):
        self.run['name'] = 'Publish addon update'
        self.run['path'] = '.github/workflows/update-addon.yml'
        self.files = {'addon.json': '{"payload":"data","signature":"signed"}'}
        self.publish()
        self.assertEqual((self.root / 'data/updates/addon.json').read_text(), self.files['addon.json'])


if __name__ == '__main__':
    unittest.main()
