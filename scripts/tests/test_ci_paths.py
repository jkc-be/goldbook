"""ci-paths.py decides which heavy Check jobs a diff can affect."""
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
CI = runpy.run_path(str(ROOT / 'scripts' / 'ci-paths.py'))


class CiPathsTests(unittest.TestCase):
    def assert_jobs(self, paths, desktop=False, stack=False, test=False):
        self.assertEqual(CI['choose'](paths), {'desktop': desktop, 'stack': stack, 'test': test})

    def test_documentation_runs_nothing(self):
        self.assert_jobs(['README.md', 'docs/guide.md', 'changes/server-note.md', 'LICENSE',
                          '.gitattributes', '.github/PULL_REQUEST_TEMPLATE/release.md'])

    def test_desktop_code_skips_the_stack(self):
        self.assert_jobs(['desktop/src-tauri/src/lib.rs'], desktop=True, test=True)

    def test_addon_and_sync_skip_the_stack(self):
        self.assert_jobs(['addon/Goldbook/Core.lua', 'crates/goldbook-sync/src/lib.rs'],
                         desktop=True, test=True)

    def test_patched_glib_runs_desktop_tests_only(self):
        self.assert_jobs(['vendor/glib/src/lib.rs'], desktop=True)

    def test_server_image_inputs_skip_desktop_tests(self):
        self.assert_jobs(['server/Dockerfile', 'server/compose.yaml', 'web/app.js'], stack=True, test=True)
        self.assert_jobs(['.dockerignore'], stack=True)

    def test_migrations_and_shared_crates_run_every_job(self):
        for path in ('server/migrations/0001_init.sql', 'crates/goldbook-core/src/lib.rs',
                     'crates/goldbook-server/src/lib.rs', 'catalog/professions.json', 'Cargo.lock',
                     'rust-toolchain.toml'):
            self.assert_jobs([path], desktop=True, stack=True, test=True)

    def test_suite_inputs_run_make_check_only(self):
        self.assert_jobs(['scripts/test.py', 'fixtures/Goldbook.lua', 'Makefile'], test=True)
        self.assert_jobs(['scripts/dev.py'], stack=True, test=True)

    def test_check_workflow_runs_every_job_and_other_workflow_files_do_not(self):
        self.assert_jobs(['.github/workflows/check.yml'], desktop=True, stack=True, test=True)
        self.assert_jobs(['.github/workflows/deploy.yml', 'package.json', '.gitignore'])

    def test_unrecognized_path_runs_every_job(self):
        self.assert_jobs(['README.md', 'tools/new.py', 'crates/goldbook-extra/src/lib.rs'],
                         desktop=True, stack=True, test=True)
        self.assertEqual(CI['choose'](None), {'desktop': True, 'stack': True, 'test': True})

    def test_rename_keeps_both_paths(self):
        blob = b'R100\0server/old.rs\0docs/new.md\0M\0README.md\0'
        paths = CI['paths_from_status'](blob)
        self.assertEqual(paths, ['server/old.rs', 'docs/new.md', 'README.md'])
        self.assert_jobs(paths, stack=True, test=True)

    def test_status_parser_rejects_a_truncated_rename(self):
        with self.assertRaises(ValueError):
            CI['paths_from_status'](b'R100\0only-the-old\0')

    def test_hand_started_and_new_branch_runs_write_every_job(self):
        for event, extra in (('workflow_dispatch', {}), ('push', {'BEFORE_SHA': '0' * 40})):
            with self.subTest(event=event):
                self.write_and_assert(event, extra, 'desktop=true\nstack=true\ntest=true\n')

    def test_missing_pull_request_base_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'out'
            with patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'pull_request',
                                          'BASE_SHA': '', 'GITHUB_OUTPUT': str(output)}):
                with self.assertRaises(SystemExit):
                    CI['main']()
            self.assertFalse(output.exists())

    def write_and_assert(self, event, extra, expected):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'out'
            env = {'GITHUB_EVENT_NAME': event, 'GITHUB_OUTPUT': str(output), **extra}
            with patch.dict(os.environ, env):
                CI['main']()
            self.assertEqual(output.read_text(), expected)


if __name__ == '__main__':
    unittest.main()
