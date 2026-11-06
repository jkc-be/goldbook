"""Local development must not use production configuration or overwrite source data."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
DEV = runpy.run_path(str(ROOT / 'scripts/dev.py'))


class DevStackTests(unittest.TestCase):
    def test_compose_ignores_production_environment_and_hides_the_backend(self):
        with patch.dict(os.environ, {'UPLOAD_TOKEN': 'production-secret',
                'GOLDBOOK_HOST': 'production.invalid', 'GOLDBOOK_IMAGE': 'production-image',
                'GOLDBOOK_DATA': '/production/data', 'BNET_CLIENT_SECRET': 'production-secret'}):
            result = DEV['compose']('config', '--format', 'json', capture_output=True, text=True)
        self.assertNotIn('production-secret', result.stdout)
        self.assertNotIn('production.invalid', result.stdout)
        config = json.loads(result.stdout)
        app = config['services']['goldbook']
        self.assertEqual(app.get('ports', []), [])
        self.assertEqual(app['image'], 'goldbook-local')
        self.assertNotIn('UPLOAD_TOKEN', app['environment'])
        labels = app['labels']
        for router in ('goldbook-web', 'goldbook-upload', 'goldbook-path', 'goldbook-path-upload'):
            base = f'traefik.http.routers.{router}'
            local = base + '-local'
            self.assertEqual(labels[local + '.entrypoints'], 'web')
            self.assertNotIn(local + '.tls', labels)
            for field in ('rule', 'service', 'middlewares'):
                self.assertEqual(labels[local + '.' + field], labels[base + '.' + field])
        self.assertEqual(app['networks']['traefik']['ipv4_address'], '172.30.254.3')
        self.assertEqual(config['services']['traefik']['networks']['traefik']['ipv4_address'],
                         '172.30.254.2')
        self.assertFalse(config['networks']['traefik'].get('external', False))
        self.assertEqual(config['services']['traefik']['image'], 'traefik:v3.7.15')
        for port in config['services']['traefik']['ports']:
            self.assertEqual(port['host_ip'], '127.0.0.1')

    def test_auction_houses_come_from_env_local_and_not_the_shell(self):
        def houses(result):
            return json.loads(result.stdout)['services']['goldbook']['environment']['GOLDBOOK_SHARDING']

        with tempfile.TemporaryDirectory() as temporary:
            env_local = Path(temporary) / '.env.local'
            with patch.dict(DEV['local_settings'].__globals__, ENV_LOCAL=env_local), \
                    patch.dict(os.environ, {'GOLDBOOK_SHARDING': 'forever'}):
                shell = DEV['compose']('config', '--format', 'json', capture_output=True, text=True)
                env_local.write_text('GOLDBOOK_SHARDING=off\n')
                local = DEV['compose']('config', '--format', 'json', capture_output=True, text=True)
        self.assertEqual(houses(shell), '')
        self.assertEqual(houses(local), 'off')

    def test_env_local_refuses_other_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            env_local = Path(temporary) / '.env.local'
            env_local.write_text('GOLDBOOK_SHARDING=off\nUPLOAD_TOKEN=production-secret\n')
            with patch.dict(DEV['local_settings'].__globals__, ENV_LOCAL=env_local), \
                    self.assertRaises(SystemExit) as refused:
                DEV['compose']('config', '--format', 'json', capture_output=True, text=True)
        self.assertEqual(str(refused.exception),
                         f'{env_local} sets only BNET_CLIENT_ID, BNET_CLIENT_SECRET, GOLDBOOK_PUBLIC_URL, '
                         'GOLDBOOK_SHARDING, not UPLOAD_TOKEN.')

    def test_database_copy_preserves_source_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'original.sqlite'
            data = root / 'local'
            data.mkdir()
            with contextlib.closing(sqlite3.connect(source)) as db, db:
                db.execute('CREATE TABLE sample (value TEXT)')
                db.execute("INSERT INTO sample VALUES ('original')")
            copy = DEV['import_database']
            with patch.dict(copy.__globals__, DATA=data), contextlib.redirect_stdout(io.StringIO()):
                copy(source)
                with self.assertRaises(SystemExit):
                    copy(source)
            with contextlib.closing(sqlite3.connect(data / 'goldbook.sqlite')) as db, db:
                db.execute("UPDATE sample SET value='local edit'")
            with contextlib.closing(sqlite3.connect(source)) as db, db:
                self.assertEqual(db.execute('SELECT value FROM sample').fetchone(), ('original',))
