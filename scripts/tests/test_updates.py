"""Exercise update-feed publication through the restricted SSH helper."""
import base64
import importlib.util
import io
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location('update_deployment', Path(__file__).parents[1] / 'deploy-ovh.py')
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)
REVISION = 'a' * 40


def addon(sequence):
    payload = json.dumps({'version': '0.1.3', 'sequence': sequence, 'revision': REVISION, 'files': {}})
    return json.dumps({'payload': base64.b64encode(payload.encode()).decode(), 'signature': 'signed'})


ADDON = addon(1760000000)


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
        self.artifacts = [{'id': 456, 'name': 'Goldbook-update-feed', 'expired': False}]
        self.relation = None
        self.compares = []

    def use_root(self, name):
        root = self.root / name
        root.mkdir()
        patch = mock.patch.object(DEPLOY, 'ROOT', root)
        patch.start()
        self.addCleanup(patch.stop)
        return root / 'data/updates'

    def release_build(self):
        self.run['name'] = 'Release build'
        self.run['path'] = '.github/workflows/release-build.yml'
        self.files['addon.json'] = ADDON

    def published_before(self):
        destination = self.root / 'data/updates'
        (destination / ('c' * 40)).mkdir(parents=True)
        (destination / ('c' * 40) / 'client.tar.gz').write_text('old package')
        (destination / 'latest.json').write_text('{"version": "0.1.2"}')
        (destination / 'addon.json').write_text(addon(1750000000))
        return self.snapshot()

    def snapshot(self, destination=None):
        destination = destination or self.root / 'data/updates'
        return {str(path.relative_to(destination)): path.read_bytes()
                for path in sorted(destination.rglob('*')) if path.is_file()}

    def response(self, request, **_):
        if request.full_url.endswith('/actions/runs/123'):
            value = json.dumps(self.run).encode()
        elif '/compare/' in request.full_url:
            self.compares.append(request.full_url.split('/compare/', 1)[1])
            value = json.dumps({'status': self.relation}).encode()
        elif request.full_url.endswith('/actions/runs/123/artifacts'):
            value = json.dumps({'artifacts': self.artifacts}).encode()
        else:
            self.assertTrue(request.full_url.endswith('/actions/artifacts/456/zip'))
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, 'w') as output:
                for name, content in self.files.items():
                    output.writestr(name, content)
            value = archive.getvalue()
        return io.BytesIO(value)

    def publish(self, check_only=False):
        with mock.patch.object(DEPLOY.OPENER, 'open', side_effect=self.response), redirect_stdout(io.StringIO()) as output:
            DEPLOY.publish_updates('123', REVISION, 'test-token', check_only=check_only)
        return json.loads(output.getvalue())

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

    def test_run_for_the_revision_needs_no_comparison(self):
        self.release_build()
        self.assertEqual(self.publish(), {'published': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual(self.compares, [])

    def test_run_dispatched_on_a_later_commit_of_main_can_publish_the_revision(self):
        before = self.published_before()
        self.run['head_sha'] = 'b' * 40
        for relation in ('behind', 'diverged'):
            self.relation = relation
            self.release_build()
            with self.subTest(relation=relation), self.assertRaisesRegex(
                    RuntimeError, f'^Run 123 is for commit {"b" * 40}, which does not contain {REVISION}$'):
                self.publish()
            self.assertEqual(self.snapshot(), before)
        self.relation = 'ahead'
        self.compares = []
        self.assertEqual(self.publish(), {'published': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual(self.compares, [REVISION + '...' + 'b' * 40])

    def test_untrusted_run_is_refused_before_any_comparison(self):
        self.run.update(head_sha='b' * 40, head_branch='other')
        with self.assertRaisesRegex(RuntimeError, 'Only a maintainer Goldbook workflow'):
            self.publish()
        self.assertEqual(self.compares, [])

    def test_rejects_untrusted_branch_workflow_path_and_missing_package(self):
        for field, value in [('head_branch', 'other'), ('path', '.github/workflows/other.yml'),
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
                publish.assert_called_once_with('123', REVISION, 'test-token', check_only=False)
            with mock.patch.dict(DEPLOY.os.environ, SSH_ORIGINAL_COMMAND='check-publish 123 ' + REVISION), \
                 mock.patch.object(DEPLOY.sys, 'stdin', io.StringIO('test-token')), \
                 mock.patch.object(DEPLOY, 'publish_updates') as publish:
                DEPLOY.main()
                publish.assert_called_once_with('123', REVISION, 'test-token', check_only=True)

    def test_addon_feed_uses_one_atomic_signed_envelope(self):
        self.run['name'] = 'Publish addon update'
        self.run['path'] = '.github/workflows/update-addon.yml'
        self.files = {'addon.json': ADDON}
        self.assertEqual(self.publish(), {'published': ['addon.json'], 'revision': REVISION})
        self.assertEqual((self.root / 'data/updates/addon.json').read_text(), ADDON)

    def test_release_build_feed_publishes_both_manifests(self):
        self.release_build()
        self.assertEqual(self.publish(), {'published': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual(self.snapshot(), {'latest.json': json.dumps(self.manifest).encode(), 'addon.json': ADDON.encode(),
                                           REVISION + '/client.tar.gz': b'signed package'})

    def test_release_build_feed_missing_a_manifest_changes_nothing(self):
        before = self.published_before()
        self.release_build()
        del self.files['addon.json']
        with self.assertRaisesRegex(RuntimeError, '^Update feed is missing addon.json$'):
            self.publish()
        self.assertEqual(self.snapshot(), before)
        self.release_build()
        del self.files['latest.json']
        with self.assertRaisesRegex(RuntimeError, '^Update feed is missing latest.json$'):
            self.publish()
        self.assertEqual(self.snapshot(), before)

    def test_run_needs_exactly_one_unexpired_feed_artifact(self):
        before = self.published_before()
        self.release_build()
        feed = {'id': 456, 'name': 'Goldbook-update-feed', 'expired': False}
        for artifacts, count in [([feed, dict(feed, id=789)], 2), ([], 0), ([dict(feed, expired=True)], 0)]:
            self.artifacts = artifacts
            with self.subTest(artifacts=artifacts), self.assertRaisesRegex(
                    RuntimeError, f'^Run 123 has {count} unexpired Goldbook-update-feed artifacts; expected exactly one$'):
                self.publish()
            self.assertEqual(self.snapshot(), before)
        self.artifacts = [feed, dict(feed, id=789, expired=True), dict(feed, id=790, name='Goldbook-addon-feed')]
        self.assertEqual(self.publish(), {'published': ['latest.json', 'addon.json'], 'revision': REVISION})

    def test_interrupted_publication_completes_with_the_same_bytes_on_retry(self):
        self.release_build()
        self.publish()
        uninterrupted = self.snapshot()
        replace = os.replace
        for stop, partial in [('latest.json', {REVISION + '/client.tar.gz'}),
                              ('addon.json', {REVISION + '/client.tar.gz', 'latest.json'})]:
            with self.subTest(stop=stop):
                destination = self.use_root('stopped-before-' + stop)

                def interrupted(source, target):
                    if Path(target) == destination / stop:
                        raise OSError('interrupted')
                    replace(source, target)
                with mock.patch.object(DEPLOY.os, 'replace', side_effect=interrupted), \
                     self.assertRaisesRegex(OSError, 'interrupted'):
                    self.publish()
                self.assertEqual(set(self.snapshot(destination)), partial)
                self.publish()
                self.assertEqual(self.snapshot(destination), uninterrupted)

    def test_older_client_version_does_not_replace_the_published_feed(self):
        before = self.published_before()
        (self.root / 'data/updates/latest.json').write_text('{"version": "0.1.10"}')
        before['latest.json'] = b'{"version": "0.1.10"}'
        self.release_build()
        for check_only in (False, True):
            with self.subTest(check_only=check_only), self.assertRaisesRegex(
                    RuntimeError, '^latest.json has version 0.1.3, older than the published version 0.1.10$'):
                self.publish(check_only=check_only)
            self.assertEqual(self.snapshot(), before)

    def test_older_addon_sequence_does_not_replace_the_published_feed(self):
        before = self.published_before()
        (self.root / 'data/updates/addon.json').write_text(addon(1770000000))
        before['addon.json'] = addon(1770000000).encode()
        self.release_build()
        for check_only in (False, True):
            with self.subTest(check_only=check_only), self.assertRaisesRegex(
                    RuntimeError, '^addon.json has sequence 1760000000, older than the published sequence 1770000000$'):
                self.publish(check_only=check_only)
            self.assertEqual(self.snapshot(), before)

    def test_same_version_and_sequence_replace_the_published_feed(self):
        self.published_before()
        destination = self.root / 'data/updates'
        (destination / 'latest.json').write_text('{"version": "0.1.3", "notes": "earlier build"}')
        (destination / 'addon.json').write_text(addon(1760000000).replace('signed', 'earlier'))
        self.release_build()
        self.assertEqual(self.publish(check_only=True), {'checked': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual(self.publish(), {'published': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual((destination / 'latest.json').read_text(), json.dumps(self.manifest))
        self.assertEqual((destination / 'addon.json').read_text(), ADDON)

    def test_unreadable_published_manifests_count_as_nothing_published(self):
        destination = self.root / 'data/updates'
        destination.mkdir(parents=True)
        (destination / 'latest.json').write_text('not json')
        (destination / 'addon.json').write_text('{"payload":"old","signature":"old"}')
        self.release_build()
        self.assertEqual(self.publish(), {'published': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual((destination / 'addon.json').read_text(), ADDON)

    def test_feed_with_an_unreadable_manifest_changes_nothing(self):
        before = self.published_before()
        for name, content in [('addon.json', '{"payload":"data","signature":"signed"}'),
                              ('latest.json', json.dumps(dict(self.manifest, version='0.1')))]:
            self.release_build()
            self.files[name] = content
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, f'^Update feed has an invalid {name}$'):
                self.publish()
            self.assertEqual(self.snapshot(), before)
            self.files['latest.json'] = json.dumps(self.manifest)

    def test_check_publish_validates_without_changing_the_feed(self):
        before = self.published_before()
        self.release_build()
        self.assertEqual(self.publish(check_only=True), {'checked': ['latest.json', 'addon.json'], 'revision': REVISION})
        self.assertEqual(self.snapshot(), before)
        self.files.pop(REVISION + '/client.tar.gz')
        with self.assertRaisesRegex(RuntimeError, 'Update package is missing'):
            self.publish(check_only=True)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
