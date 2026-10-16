#!/usr/bin/env python3
"""Run the OVH Compose stack locally, with isolated data and credentials."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import secrets
import subprocess
import time
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'data/dev'
TOKEN = 'goldbook-local-development'


def compose(*args, **kwargs):
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'DOCKER_CONFIG', 'DOCKER_HOST', 'DOCKER_CONTEXT')
           if key in os.environ}
    env.update(GOLDBOOK_HOST='goldbook.localhost', GOLDBOOK_PATH_HOST='localhost',
               TRAEFIK_NETWORK='goldbook-dev-traefik', TRUSTED_PROXY='172.30.254.2/32',
               GOLDBOOK_IMAGE='goldbook-local', GOLDBOOK_DATA=str(DATA),
               GOLDBOOK_USER=f'{os.getuid()}:{os.getgid()}', UPLOAD_TOKEN=TOKEN,
               SELF_REGISTRATION='true')
    command = ['docker', 'compose', '-p', 'goldbook-dev', '--env-file', os.devnull]
    for name in ('compose.yaml', 'compose.traefik.yaml', 'compose.path.yaml', 'compose.local.yaml'):
        command += ['-f', str(ROOT / 'server' / name)]
    # Derive HTTP routes from production labels so upload rules cannot drift.
    rendered = subprocess.run(command + ['config', '--format', 'json'],
                              cwd=ROOT, env=env, check=True, capture_output=True, text=True)
    labels = json.loads(rendered.stdout)['services']['goldbook']['labels']
    local = {}
    for key, value in labels.items():
        if not key.startswith('traefik.http.routers.') or '.tls' in key:
            continue
        parts = key.split('.')
        parts[3] += '-local'
        local['.'.join(parts)] = 'web' if parts[4] == 'entrypoints' else value
    # JSON is valid Compose YAML. Escape dollars against a second interpolation.
    overlay = {'services': {'goldbook': {'labels': {
        key: value.replace('$', '$$') for key, value in local.items()
    }}}}
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as generated:
        json.dump(overlay, generated)
        generated.flush()
        return subprocess.run(command + ['-f', generated.name] + list(args),
                              cwd=ROOT, env=env, check=True, **kwargs)


def import_database(source):
    destination = DATA / 'goldbook.sqlite'
    if destination.exists():
        raise SystemExit(f'{destination} already exists; refusing to replace local data.')
    source = source.resolve(strict=True)
    with sqlite3.connect(source.as_uri() + '?mode=ro', uri=True) as original:
        with sqlite3.connect(destination) as copied:
            original.backup(copied)
            assert copied.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
    print(f'Copied {source} into {destination}; the source was opened read-only.', flush=True)


def request(host, path, body=None, token=None, scheme="https"):
    port = 8443 if scheme == "https" else 8080
    # Only this loopback development stack uses Traefik's self-signed certificate.
    command = ['curl', '--silent', '--show-error', '--insecure', '--noproxy', '*',
               '--resolve', f'{host}:{port}:127.0.0.1', '--max-time', '30',
               '--write-out', '\n%{http_code}', f'{scheme}://{host}:{port}{path}']
    if body is not None:
        command += ['-H', 'Content-Type: application/json', '--data-binary', '@-']
    if token:
        command += ['-H', f'Authorization: Bearer {token}']
    result = subprocess.run(command, input=body, capture_output=True, check=True)
    content, status = result.stdout.rsplit(b'\n', 1)
    return int(status), content


def verify():
    for _ in range(60):
        try:
            if request('localhost', '/goldbook/api/realms')[0] == 200:
                break
        except subprocess.CalledProcessError:
            pass
        time.sleep(1)
    else:
        raise RuntimeError('Local Traefik did not become ready')
    # Invalid JSON padded above the old proxy limit reaches app validation,
    # without adding any test records to the user's development database.
    body = b' ' * 70000 + b'['
    for host, prefix in (('goldbook.localhost', ''), ('localhost', '/goldbook')):
        assert request(host, prefix + '/api/realms')[0] == 200
        path = prefix + '/api/sellers/batch'
        for token in (None, 'wrong'):
            for _ in range(4):
                status, response = request(host, path, b' ' * (1024 * 1024), token)
                assert status == 401, f'{host}{path}: upload must reach authentication, got {status}: {response[:200]}'
        assert request(host, path, body, TOKEN)[0] == 400, 'large batch must reach JSON validation'
        assert request(host, prefix + '/api/login', body)[0] == 413, 'public route must keep its small limit'
    for scheme in ('http', 'https'):
        for host, prefix in (('goldbook.localhost', ''), ('localhost', '/goldbook')):
            # A fresh identity proves automatic setup and its token work through the proxy.
            payload = json.dumps({'fingerprint': secrets.token_hex(32),
                                  'fingerprintVersion': 1}).encode()
            status, response = request(host, prefix + '/api/installations', payload, scheme=scheme)
            assert status == 200, f'automatic setup returned {status}'
            token = json.loads(response)['token']
            assert token.startswith('gb_')
            assert request(host, prefix + '/api/sellers/batch', body, token, scheme)[0] == 400
            assert request(host, prefix + '/api/sellers/batch', body, scheme=scheme)[0] == 401
            assert request(host, prefix + '/api/login', body, scheme=scheme)[0] == 413
            assert b'id="chart"' in request(host, prefix + '/', scheme=scheme)[1]
    print('Verified HTTP and HTTPS routes, automatic upload setup, authentication and upload buffering.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('up', 'down', 'logs', 'check', 'config'), nargs='?', default='up')
    parser.add_argument('--database', type=Path, help='Copy this SQLite database on first start only')
    args = parser.parse_args()
    if args.database and args.command != 'up':
        parser.error('--database is only valid with up')
    if args.command == 'up':
        DATA.mkdir(parents=True, exist_ok=True)
        if args.database:
            import_database(args.database)
        compose('up', '-d', '--build', '--wait', '--wait-timeout', '120')
        verify()
        print('Desktop API and web: http://localhost:8080/goldbook/\n'
              'HTTPS web: https://localhost:8443/goldbook/\n'
              'Dedicated host: https://goldbook.localhost:8443/\n'
              'TLS uses a local self-signed certificate; no production credentials are loaded.\n'
              f'Data: {DATA}\nStop with make dev-down; data is kept.')
    elif args.command == 'check':
        verify()
    elif args.command == 'config':
        compose('config')
    elif args.command == 'logs':
        compose('logs', '-f', '--tail', '100')
    else:
        compose('down')


if __name__ == '__main__':
    main()
