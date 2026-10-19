#!/usr/bin/env python3
"""Exercise production Traefik routing against a disposable local Goldbook server."""
import contextlib
import copy
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import runpy
import socket
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / 'scripts/verify-migration.py'))
VERSION = '3.7.15'
CHECKSUMS = {
    'darwin_amd64': '9bb903e320eda7950c5ae3289b5d4e383a03bf0568a28cd0b919a7ebb8545bba',
    'darwin_arm64': '402f59cef47bbba629dda7ee34e99897648634fac8dc020fb992a7cdb034d323',
    'linux_amd64': '5b9f51199fcb7a3b5f7ae0f9dae8dcf01efadafd92c5fca96ea2822eca81f8e6',
    'linux_arm64': '1866d8e831b95d14b599bb59eb20d2033b979c0cb1e347b48a0866a9b810454e',
}


def traefik_binary():
    machine = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine(), platform.machine())
    target = f'{platform.system().lower()}_{machine}'
    if target not in CHECKSUMS:
        raise RuntimeError(f'Unsupported Traefik test platform: {target}')
    cache = ROOT / 'target/test-tools' / f'traefik-{VERSION}-{target}'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / 'traefik.tar.gz'
    if not archive.exists():
        url = f'https://github.com/traefik/traefik/releases/download/v{VERSION}/traefik_v{VERSION}_{target}.tar.gz'
        subprocess.run(['curl', '-fLsS', '--retry', '3', '-o', str(archive), url], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != CHECKSUMS[target]:
        archive.unlink()
        raise RuntimeError('Traefik archive checksum mismatch; removed cached download')
    binary = cache / 'traefik'
    with tarfile.open(archive) as bundle:
        binary.write_bytes(bundle.extractfile('traefik').read())
    binary.chmod(0o755)
    return binary


def production_config(backend_port):
    # Render the real files with a clean environment: never load production .env.
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'DOCKER_CONFIG') if k in os.environ}
    env.update(GOLDBOOK_HOST='localhost', GOLDBOOK_PATH_HOST='127.0.0.1',
               TRUSTED_PROXY='127.0.0.1/32')
    command = ['docker', 'compose', '--env-file', os.devnull]
    for file in ('compose.yaml', 'compose.traefik.yaml', 'compose.path.yaml'):
        command += ['-f', str(ROOT / 'server' / file)]
    rendered = json.loads(subprocess.check_output(command + ['config', '--format', 'json'], env=env))
    labels = rendered['services']['goldbook']['labels']
    # Traefik's file provider uses the same router/middleware configuration as
    # Docker labels. Only discovery, backend address and TLS differ locally.
    case = {'ratelimit': 'rateLimit', 'sourcecriterion': 'sourceCriterion',
            'ipstrategy': 'ipStrategy', 'ipv6subnet': 'ipv6Subnet',
            'maxrequestbodybytes': 'maxRequestBodyBytes', 'stsseconds': 'stsSeconds',
            'stripprefix': 'stripPrefix', 'redirectregex': 'redirectRegex',
            'entrypoints': 'entryPoints'}
    config = {'http': {'routers': {}, 'middlewares': {}, 'services': {
        'goldbook-web': {'loadBalancer': {'servers': [{'url': f'http://127.0.0.1:{backend_port}'}]}}
    }}}
    for key, value in labels.items():
        if not key.startswith(('traefik.http.routers.', 'traefik.http.middlewares.')):
            continue
        # Compose config preserves dollar escapes for reloading; container labels do not.
        value = value.replace('$$', '$')
        parts = key.split('.')[1:]
        if parts[1] == 'routers' and parts[3] == 'tls':
            continue  # Local HTTP only: no ACME, public DNS or certificates.
        leaf = parts[-1]
        if leaf in ('middlewares', 'entrypoints', 'prefixes'):
            value = value.split(',')
        elif value in ('true', 'false'):
            value = value == 'true'
        elif value.isdigit():
            value = int(value)
        node = config
        for part in parts[:-1]:
            node = node.setdefault(case.get(part, part), {})
        node[case.get(leaf, leaf)] = value
    return config


def request(port, host, path, body=None, token=None, extra=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    headers = {'Host': f'{host}:{port}', **(extra or {})}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    if body is not None:
        headers['Content-Type'] = 'application/json'
    try:
        try:
            connection.request('POST' if body is not None else 'GET', path, body, headers)
        except BrokenPipeError:
            # Traefik can reject Content-Length before reading a large body.
            # Read and assert its HTTP response rather than treating this as success.
            pass
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


@contextlib.contextmanager
def proxy(directory, binary, config):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    # JSON is valid YAML, and avoids another parser dependency.
    settings = directory / 'traefik-dynamic.yaml'
    settings.write_text(json.dumps(config))
    with (directory / 'traefik.log').open('w+') as log:
        process = subprocess.Popen([str(binary), f'--entrypoints.websecure.address=127.0.0.1:{port}',
            f'--providers.file.filename={settings}', '--providers.file.watch=false',
            '--global.checknewversion=false', '--global.sendanonymoususage=false',
            '--accesslog=true', '--accesslog.format=json'],
            cwd=directory, stdout=log, stderr=log,
            env={k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR') if k in os.environ})
        try:
            for _ in range(200):
                if process.poll() is not None:
                    raise RuntimeError('Traefik exited before becoming ready')
                try:
                    if request(port, 'localhost', '/api/realms')[0] == 200:
                        break
                except OSError:
                    pass
                time.sleep(.05)
            else:
                raise RuntimeError('Traefik did not become ready')
            yield port
        except BaseException:
            log.seek(0)
            print(log.read(), flush=True)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def exercise(port, directory, upload):
    snapshots = [dict(realm='ProxyTest', faction='Horde', itemKey=str(20000+i),
                      scannedAt=1760000000, offers=[dict(unitPrice=100+j, quantity=2,
                      owners=['Seller-ProxyTest'], totalOwners=1) for j in range(20)])
                 for i in range(100)]
    body = json.dumps(snapshots).encode()
    assert len(body) > 65536
    for index, (host, prefix) in enumerate((('localhost', ''), ('127.0.0.1', '/goldbook'))):
        path = prefix + '/api/sellers/batch'
        for token in (None, 'wrong'):
            for _ in range(4):
                status, _, response = request(port, host, path, b' ' * (1024 * 1024), token)
                assert status == 401, f'{host}{path}: upload must reach authentication, got {status}: {response[:200]}'
        status, _, raw = request(port, host, path, body, upload)
        assert status == 200, f'{host}{path}: expected 200 for {len(body)} bytes, got {status}: {raw[:200]}'
        assert json.loads(raw) == {'received': 100, 'stored': 100 if index == 0 else 0}
        assert json.loads(request(port, host, path, body, upload)[2])['stored'] == 0
        invalid = copy.deepcopy(snapshots)
        invalid[0]['itemKey'] = '99999'
        invalid[-1]['scannedAt'] = 0
        assert request(port, host, path, json.dumps(invalid).encode(), upload)[0] == 400
        query = prefix + '/api/sellers?realm=ProxyTest&faction=Horde&itemKey='
        status, _, raw = request(port, host, query + '20000')
        book = json.loads(raw)['snapshot']['orderBook']
        assert status == 200 and len(book) == 20 and book[-1]['cumulativeQuantity'] == 40
        assert json.loads(request(port, host, query + '99999')[2])['snapshot'] is None
        assert request(port, host, prefix + '/api/login', body)[0] == 413, 'public routes keep 64 KiB buffer'
        assert request(port, host, path, b' ' * (20 * 1024 * 1024 + 1), upload)[0] == 413
        if index == 0:
            rows = [[str(30000 + i), 1000 + i, 0, 1, 0] for i in range(40000)]
            scan = dict(realm='ProxyExport', faction='Horde', region='EU', scannedAt=1760000000, mode='browse',
                        scanner='Proxy', build='1.15.7', rows=rows, items={})
            assert request(port, host, prefix + '/api/scans', json.dumps(scan).encode(), upload)[0] == 200
        for _ in range(3):
            status, _, raw = request(port, host, prefix + '/api/export?realm=ProxyExport&faction=Horde')
            assert status == 200 and len(raw) > 2 * 1024 * 1024, f'{host}{prefix}: export got {status}, {len(raw)} bytes'
            assert json.loads(raw)['items']['69999']['price'] == [40999, 1, 0, 1760000000, 0, 0]
            status, headers, zipped = request(port, host, prefix + '/api/export?realm=ProxyExport&faction=Horde',
                                              extra={'Accept-Encoding': 'gzip'})
            encoding = {name.lower(): value for name, value in headers.items()}.get('content-encoding')
            assert status == 200 and encoding == 'gzip', f'{host}{prefix}: export got {status}, encoding {encoding}'
            assert gzip.decompress(zipped) == raw and len(zipped) < len(raw) / 3, (len(zipped), len(raw))
        # Drive the actual sync executable through Traefik, including lost state.
        fixture = directory / 'Books.lua'
        subprocess.run(['luajit', 'addon/tests/orderbook.lua', str(fixture)], cwd=ROOT, check=True)
        for state in ('state.json', 'state.json', 'lost-state.json'):
            subprocess.run([str(ROOT / 'target/debug/goldbook-sync'), '--once', '--file', str(fixture),
                '--api', f'http://{host}:{port}{prefix}', '--token', upload,
                '--state', str(directory / f'{index}-{state}')], cwd=ROOT, check=True)
        print(f'Verified {host}{prefix}: {len(body):,}-byte batch, auth, readback, retries, atomic validation, body limits and a {len(raw):,}-byte export sent as {len(zipped):,} gzip bytes.', flush=True)
    status, headers, _ = request(port, '127.0.0.1', '/goldbook')
    assert status == 301 and headers['Location'].endswith('/goldbook/')
    return body


def main():
    binary = traefik_binary()
    with tempfile.TemporaryDirectory(prefix='goldbook-proxy-') as temporary:
        directory = Path(temporary)
        with HELPERS['server'](directory, None, ROOT / 'target/debug/goldbook-server') as api:
            config = production_config(api.port)
            with proxy(directory, binary, config) as port:
                body = exercise(port, directory, api.token)
            # Prove this test setup reproduces the production regression.
            broken = copy.deepcopy(config)
            for router in broken['http']['routers'].values():
                for prefix in ('', '/goldbook'):
                    router['rule'] = router['rule'].replace(f' || Path(`{prefix}/api/sellers/batch`)', '')
            with proxy(directory, binary, broken) as port:
                for host, prefix in (('localhost', ''), ('127.0.0.1', '/goldbook')):
                    assert request(port, host, prefix + '/api/sellers/batch', body, api.token)[0] == 413
            print('Negative control reproduced HTTP 413 when batch upload routes were removed.')
    print('Local Traefik verification passed; temporary server, proxy and database removed.')


if __name__ == '__main__':
    main()
