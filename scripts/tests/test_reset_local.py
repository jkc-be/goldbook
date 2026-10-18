"""Exercise the destructive reset against temporary homes and game installations."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'reset-local.py'
spec = importlib.util.spec_from_file_location('reset_local', SCRIPT)
reset_local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset_local)


class ResetLocalTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / 'home'
        self.repo = self.root / 'repo'
        self.game = self.root / 'custom game'
        self.app = self.root / 'Applications/Goldbook.app'
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        discovery = patch.object(reset_local, 'wow_candidates', return_value=[self.root / 'default game'])
        discovery.start()
        self.addCleanup(discovery.stop)
        app_path = patch.object(reset_local, 'MAC_APP', self.app)
        app_path.start()
        self.addCleanup(app_path.stop)
        self.output = redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def write(self, path, text='old data'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def prepare(self, platform):
        if platform == 'darwin':
            self.write(self.app / 'Contents/MacOS/Goldbook', 'app executable')
        base = (self.home / 'Library/Application Support' if platform == 'darwin'
                else self.home / '.config')
        self.settings = self.write(base / 'Goldbook/settings.json', json.dumps({'wowDir': str(self.game)}))
        self.sync = self.write(self.home / '.config/goldbook/state.json')
        self.database = self.write(self.repo / 'data/goldbook.sqlite')
        self.cache = self.write((self.home / 'Library/WebKit' if platform == 'darwin'
                                 else self.home / '.local/share') / 'app.goldbook.desktop/cookies.db')
        self.addon = self.game / '_classic_/Interface/AddOns/Goldbook'
        self.source = self.write(self.addon / 'Goldbook.toc', 'ServerData.lua\n')
        self.prices = self.write(self.addon / 'ServerData.lua')
        self.saved = []
        for flavor, account in (('_classic_', 'ONE'), ('_retail_', 'TWO')):
            for suffix in ('', '.bak'):
                self.saved.append(self.write(self.game / flavor / 'WTF/Account' / account
                                             / f'SavedVariables/Goldbook.lua{suffix}'))
        self.character = self.write(self.game / '_classic_/WTF/Account/ONE/Realm/Character/SavedVariables/Goldbook.lua')
        self.other = self.write(self.game / '_classic_/WTF/Account/ONE/SavedVariables/OtherAddon.lua')
        self.untouched = self.write(self.repo / '.env', 'local server settings')

    def run_reset(self, platform='darwin', **kwargs):
        return reset_local.reset(self.home, platform, self.repo, **kwargs)

    def test_reset_plan_is_confined_to_temporary_fixtures(self):
        for platform in ('darwin', 'linux'):
            self.prepare(platform)
            paths, prices = reset_local.plan(self.home, platform, self.repo, [])
            for path in paths + prices:
                self.assertTrue(path.is_relative_to(self.root), str(path))

    def test_mac_reset_removes_all_state_and_preserves_addon_and_other_data(self):
        self.prepare('darwin')
        launch = self.write(self.home / 'Library/LaunchAgents/goldbook-desktop.plist')
        preferences = self.write(self.home / 'Library/Preferences/app.goldbook.desktop.plist')
        backup = self.write(self.addon.parent / '.Goldbook-backup/ServerData.lua')
        with patch.object(reset_local.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')) as run:
            self.run_reset()
            run.assert_any_call(['tccutil', 'reset', 'All', 'app.goldbook.desktop'], check=True)
            run.assert_any_call(['launchctl', 'bootout', f'gui/{os.getuid()}', str(launch)], check=True)
            run.assert_any_call(['defaults', 'delete', 'app.goldbook.desktop'], check=True)
            self.run_reset()  # A second reset is safe when the data is already gone.
        for path in (self.settings, self.sync, self.database, self.cache, launch, preferences, backup,
                     self.character, *self.saved):
            self.assertFalse(path.exists(), str(path))
        self.assertEqual(self.prices.read_text(), '-- Cleared by make reset-local.\nGoldbookServerData = nil\n')
        self.assertEqual(self.source.read_text(), 'ServerData.lua\n')
        self.assertEqual(self.other.read_text(), 'old data')
        self.assertEqual(self.untouched.read_text(), 'local server settings')
        self.assertFalse(self.app.exists())

    def test_mac_permissions_are_reset_before_uninstalling_only_goldbook(self):
        self.prepare('darwin')
        other_app = self.write(self.app.parent / 'Other.app/Contents/MacOS/Other', 'other executable')

        def command(args, **kwargs):
            if args[0] == 'tccutil':
                self.assertTrue(self.app.is_dir())
            return subprocess.CompletedProcess(args, 0, stdout='')

        with patch.object(reset_local.subprocess, 'run', side_effect=command):
            self.run_reset()
        self.assertFalse(self.app.exists())
        self.assertEqual(other_app.read_text(), 'other executable')

    def test_linux_resets_xdg_data_and_custom_settings_and_game(self):
        self.prepare('linux')
        app = self.write(self.app / 'Contents/MacOS/Goldbook', 'mac executable')
        custom_settings = self.write(self.root / 'custom-settings.json', json.dumps({'wowDir': str(self.game)}))
        extra_game = self.root / 'another game'
        extra_saved = self.write(extra_game / '_retail_/WTF/Account/THREE/SavedVariables/Goldbook.lua')
        xdg = self.root / 'xdg'
        xdg_data = self.write(xdg / 'app.goldbook.desktop/cookies.db')
        with patch.dict(os.environ, {'XDG_DATA_HOME': str(xdg), 'GOLDBOOK_CONFIG': str(custom_settings)}):
            with patch.object(reset_local.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')) as run:
                self.run_reset('linux', extra_wow=[extra_game])
                self.assertEqual(run.call_count, 1)  # Only the process check, no macOS commands.
        for path in (custom_settings, xdg_data, extra_saved, self.settings, self.sync, self.database, *self.saved):
            self.assertFalse(path.exists(), str(path))
        self.assertEqual(app.read_text(), 'mac executable')

    def test_preview_changes_nothing_and_runs_no_commands(self):
        self.prepare('darwin')
        with patch.object(reset_local.subprocess, 'run') as run:
            self.run_reset(dry_run=True)
            run.assert_not_called()
        self.assertEqual(self.prices.read_text(), 'old data')
        for path in (self.settings, self.sync, self.database, self.cache, *self.saved):
            self.assertTrue(path.exists(), str(path))
        self.assertTrue(self.app.is_dir())

    def test_running_game_or_client_prevents_any_reset(self):
        self.prepare('darwin')
        for process in ('/Applications/Goldbook.app/Contents/MacOS/goldbook-desktop',
                        'goldbook-deskto', 'WowClassic.exe', 'goldbook-server'):
            with self.subTest(process=process):
                with patch.object(reset_local.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=process)) as run:
                    with self.assertRaisesRegex(RuntimeError, 'Quit these programs first'):
                        self.run_reset()
                    self.assertEqual(run.call_count, 1)
                self.assertTrue(self.settings.exists())
                self.assertEqual(self.prices.read_text(), 'old data')

    def test_running_docker_server_prevents_reset(self):
        self.prepare('linux')
        database = self.write(self.repo / 'data/dev/goldbook.sqlite')
        with patch.object(reset_local.shutil, 'which', return_value='/usr/bin/docker'):
            with patch.object(reset_local.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, stdout=''),
                subprocess.CompletedProcess([], 0, stdout='container-id'),
            ]):
                with self.assertRaisesRegex(RuntimeError, 'make dev-down'):
                    self.run_reset('linux')
        self.assertEqual(database.read_text(), 'old data')
        self.assertTrue(self.settings.exists())

    def test_failed_permission_reset_is_reported_before_deleting_data(self):
        self.prepare('darwin')
        with patch.object(reset_local.subprocess, 'run', side_effect=[
            subprocess.CompletedProcess([], 0, stdout=''),
            subprocess.CalledProcessError(1, ['tccutil']),
        ]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_reset()
        self.assertTrue(self.settings.exists())
        self.assertEqual(self.prices.read_text(), 'old data')
        self.assertTrue(self.app.is_dir())

    def test_unreadable_game_data_prevents_reset(self):
        self.prepare('darwin')
        def unreadable(*args, **kwargs):
            kwargs['onerror'](PermissionError('SavedVariables access denied'))
        with patch.object(reset_local.os, 'walk', side_effect=unreadable):
            with self.assertRaisesRegex(PermissionError, 'access denied'):
                self.run_reset()
        self.assertTrue(self.settings.exists())
        self.assertEqual(self.prices.read_text(), 'old data')

    def test_linked_addon_cannot_modify_source_checkout(self):
        source = self.root / 'source'
        original = self.write(source / 'ServerData.lua')
        addon = self.game / '_classic_/Interface/AddOns/Goldbook'
        addon.parent.mkdir(parents=True)
        addon.symlink_to(source, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'is a symlink'):
            self.run_reset(extra_wow=[self.game], dry_run=True)
        self.assertEqual(original.read_text(), 'old data')

    def test_linked_prices_and_app_folder_do_not_delete_target_data(self):
        self.prepare('darwin')
        external = self.write(self.root / 'external/prices.lua')
        self.prices.unlink()
        self.prices.symlink_to(external)
        cache = self.home / 'Library/Caches/Goldbook'
        cache.parent.mkdir(parents=True)
        cache.symlink_to(external.parent, target_is_directory=True)
        with patch.object(reset_local.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')):
            self.run_reset()
        self.assertEqual(external.read_text(), 'old data')
        self.assertFalse(cache.is_symlink())
        self.assertFalse(self.prices.is_symlink())
        self.assertIn('GoldbookServerData = nil', self.prices.read_text())


if __name__ == '__main__':
    unittest.main()
