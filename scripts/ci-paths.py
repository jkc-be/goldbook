#!/usr/bin/env python3
"""Choose the heavy Check jobs a diff can affect.

`desktop` runs `cargo test -p goldbook-desktop`, `stack` builds the local
Compose server, and `test` runs `make check`. Documentation runs none of
them. An unrecognized path runs all of them, and so does a workflow started
by hand: Deploy to OVH calls Check that way, and a called workflow reports
its caller's event.
"""
import os
from pathlib import Path
import re
import subprocess

JOBS = ('desktop', 'stack', 'test')
RUST_ROOTS = ('Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml')
# These files do not feed the three jobs above. The secrets job still runs.
METADATA = ('package.json', 'package-lock.json', '.gitignore', '.gitleaks.toml')
SHA = re.compile(r'[0-9a-f]{40}')


def prose(path):
    return (path.startswith(('docs/', 'changes/', '.github/PULL_REQUEST_TEMPLATE/'))
            or path.endswith('.md') or path in ('LICENSE', '.gitattributes'))


def jobs_for(path):
    """Jobs one path can affect. None means the path is unrecognized."""
    if prose(path):
        return set()
    if path == '.github/workflows/check.yml':
        return set(JOBS)
    if path.startswith('.github/') or path in METADATA:
        return set()
    if path == '.dockerignore':
        return {'stack'}
    # make check formats the desktop crate; cargo test does not run it.
    if path.startswith('desktop/'):
        return {'desktop', 'test'}
    # GTK's patched glib is linked by the desktop crate only.
    if path.startswith('vendor/'):
        return {'desktop'}
    # The sync crate embeds the addon. The server does not link that crate.
    if path.startswith(('addon/', 'crates/goldbook-sync/')):
        return {'desktop', 'test'}
    if (path.startswith('web/')
            or path.startswith('server/') and not path.startswith('server/migrations/')):
        return {'stack', 'test'}
    # The server crate embeds these, and the desktop tests link that crate.
    if (path.startswith(('server/migrations/', 'crates/goldbook-core/', 'crates/goldbook-server/', 'catalog/'))
            or path in RUST_ROOTS):
        return set(JOBS)
    if path == 'scripts/dev.py':
        return {'stack', 'test'}
    if path.startswith(('scripts/', 'fixtures/')) or path == 'Makefile':
        return {'test'}
    return None


def choose(paths):
    """Jobs to run. None for `paths` means the diff could not be read."""
    if paths is None:
        return {job: True for job in JOBS}
    selected = {job: False for job in JOBS}
    for path in paths:
        jobs = jobs_for(path)
        if jobs is None:
            return {job: True for job in JOBS}
        selected.update({job: True for job in jobs})
    return selected


def paths_from_status(blob):
    """Paths from `git diff --name-status -z`, including both sides of a rename."""
    fields = blob.split(b'\0')
    if fields and fields[-1] == b'':
        fields.pop()
    paths = []
    index = 0
    while index < len(fields):
        status = fields[index].decode()
        count = 2 if status[:1] in ('R', 'C') else 1
        chunk = fields[index + 1:index + 1 + count]
        if len(chunk) != count:
            raise ValueError('truncated git diff')
        paths.extend(part.decode() for part in chunk)
        index += 1 + count
    return paths


def diff_base():
    event = os.environ.get('GITHUB_EVENT_NAME', '')
    if event == 'pull_request':
        return os.environ.get('BASE_SHA', '')
    if event == 'push':
        before = os.environ.get('BEFORE_SHA', '')
        if before and set(before) <= {'0'}:
            return None
        return before
    return None


def diff_paths():
    base = diff_base()
    if base is None and os.environ.get('GITHUB_EVENT_NAME') == 'push':
        return None
    if not SHA.fullmatch(base or ''):
        raise SystemExit('the diff base is missing')
    result = subprocess.run(
        ['git', 'diff', '--name-status', '-z', '--find-renames', base, 'HEAD'],
        check=True, capture_output=True)
    return paths_from_status(result.stdout)


def write_outputs(selected):
    lines = ''.join(f'{job}={"true" if selected[job] else "false"}\n' for job in JOBS)
    print(' '.join(line.strip() for line in lines.splitlines()))
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with Path(output).open('a') as handle:
            handle.write(lines)


def main():
    event = os.environ.get('GITHUB_EVENT_NAME', '')
    if event in ('pull_request', 'push'):
        selected = choose(diff_paths())
    else:
        selected = choose(None)
    write_outputs(selected)


if __name__ == '__main__':
    main()
