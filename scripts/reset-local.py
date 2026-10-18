#!/usr/bin/env python3
"""Delete local Goldbook data for a fresh-install test. Does not contact a server."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = json.loads((ROOT / 'desktop/src-tauri/tauri.conf.json').read_text())
IDENTIFIER = APP['identifier']
NAMES = (APP['productName'], 'goldbook-desktop', 'goldbook')
STUB = '-- Cleared by make reset-local.\nGoldbookServerData = nil\n'


def app_paths(home, platform):
    paths = [home / '.config/goldbook']
    if platform == 'darwin':
        library = home / 'Library'
        for directory in ('Application Support', 'Caches', 'Logs', 'WebKit', 'HTTPStorages'):
            paths.extend(library / directory / name for name in (*NAMES, IDENTIFIER))
        paths.extend([
            library / 'Preferences' / f'{IDENTIFIER}.plist',
            library / 'Cookies' / f'{IDENTIFIER}.binarycookies',
            library / 'Saved Application State' / f'{IDENTIFIER}.savedState',
        ])
        paths.extend(library / 'LaunchAgents' / f'{name}.plist' for name in NAMES)
    else:
        for variable, default in (('XDG_CONFIG_HOME', '.config'),
                                  ('XDG_DATA_HOME', '.local/share'),
                                  ('XDG_CACHE_HOME', '.cache'),
                                  ('XDG_STATE_HOME', '.local/state')):
            base = Path(os.environ.get(variable) or home / default)
            paths.extend(base / name for name in (*NAMES, IDENTIFIER))
        paths.extend(home / '.config/autostart' / f'{name}.desktop' for name in NAMES)
    return list(dict.fromkeys(paths))


def settings_paths(home, platform):
    base = (home / 'Library/Application Support' if platform == 'darwin'
            else Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config'))
    paths = [base / APP['productName'] / 'settings.json']
    if os.environ.get('GOLDBOOK_CONFIG'):
        paths.append(Path(os.environ['GOLDBOOK_CONFIG']).expanduser().absolute())
    return paths


def entries(path):
    try:
        return list(path.iterdir())
    except (FileNotFoundError, NotADirectoryError):
        return []


def walk_error(error):
    raise error


def wow_candidates(home, platform):
    if platform == 'darwin':
        return [Path('/Applications/World of Warcraft')]
    prefixes = [home / '.wine', home / '.local/share/wineprefixes/wow']
    games = []
    for root in ('Games', '.var/app/net.lutris.Lutris/data/games'):
        for path in entries(home / root):
            prefixes.append(path)
            if path.name.lower() == 'world of warcraft':
                games.append(path)
    for root in ('.local/share/bottles/bottles',
                 '.var/app/com.usebottles.bottles/data/bottles/bottles'):
        prefixes.extend(entries(home / root))
    for root in ('.steam/steam', '.steam/debian-installation', '.local/share/Steam',
                 '.var/app/com.valvesoftware.Steam/data/Steam', 'snap/steam/common/.local/share/Steam'):
        prefixes.extend(path / 'pfx' for path in entries(home / root / 'steamapps/compatdata'))
    return games + [prefix / 'drive_c' / program / 'World of Warcraft'
                    for prefix in prefixes for program in ('Program Files (x86)', 'Program Files')]


def plan(home, platform, root, extra_wow):
    paths = app_paths(home, platform) + [root / 'data']
    games = wow_candidates(home, platform) + list(extra_wow)
    for settings in settings_paths(home, platform):
        paths.extend([settings, settings.with_suffix('.json.tmp')])
        if settings.is_file():
            try:
                saved = json.loads(settings.read_text())
                if isinstance(saved, dict) and isinstance(saved.get('wowDir'), str) and saved['wowDir']:
                    games.append(Path(saved['wowDir']).expanduser().absolute())
            except (ValueError, UnicodeError):
                print(f'Cannot read {settings}; using the default and supplied WoW folders.', file=sys.stderr)
    server_data = []
    for game in dict.fromkeys(games):
        for flavor in entries(game):
            if not (flavor.name.startswith('_') and flavor.name.endswith('_') and flavor.is_dir()):
                continue
            accounts = flavor / 'WTF/Account'
            if accounts.exists():
                for directory, subdirs, files in os.walk(accounts, followlinks=False, onerror=walk_error):
                    if Path(directory).name == 'SavedVariables':
                        paths.extend(Path(directory) / name for name in files
                                     if name.lower() in ('goldbook.lua', 'goldbook.lua.bak'))
            addon = flavor / 'Interface/AddOns/Goldbook'
            if addon.is_symlink():
                raise RuntimeError(f'{addon} is a symlink. Replace it with an installed addon before resetting.')
            if addon.is_dir():
                server_data.append(addon / 'ServerData.lua')
            paths.append(flavor / 'Interface/AddOns/.Goldbook-backup')
            paths.extend(path for path in entries(flavor / 'Interface/AddOns')
                         if path.name.startswith('.Goldbook-update-'))
    return list(dict.fromkeys(paths)), list(dict.fromkeys(server_data))


def check_stopped(root):
    result = subprocess.run(['ps', '-axo', 'comm='], check=True, capture_output=True, text=True)
    running = {Path(line.strip()).name.lower().removesuffix('.exe') for line in result.stdout.splitlines()}
    # Linux comm names are limited to 15 characters.
    blocked = running & {'goldbook', 'goldbook-desktop', 'goldbook-deskto', 'goldbook-sync', 'goldbook-server',
                         'wow', 'wowclassic', 'wowclassicera', 'wowt', 'wowb'}
    if blocked:
        raise RuntimeError('Quit these programs first: ' + ', '.join(sorted(blocked)))
    if (root / 'data/dev').exists() and shutil.which('docker'):
        containers = subprocess.run(
            ['docker', 'ps', '-q', '--filter', 'label=com.docker.compose.project=goldbook-dev'],
            capture_output=True, text=True,
        )
        if containers.returncode:
            raise RuntimeError('Cannot check the local Docker stack. Stop it before resetting and retry with Docker available.')
        if containers.stdout.strip():
            raise RuntimeError('Stop the local server first with make dev-down.')


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def reset(home, platform, root, extra_wow=(), dry_run=False):
    if platform not in ('darwin', 'linux'):
        raise RuntimeError('reset-local currently supports macOS and Linux.')
    paths, server_data = plan(home, platform, root, extra_wow)
    existing = [path for path in paths if path.exists() or path.is_symlink()]
    for path in existing:
        print(f'Will delete {path}', flush=True)
    for path in server_data:
        print(f'Will reset {path}', flush=True)
    if platform == 'darwin':
        print(f'Reset macOS privacy permissions: tccutil reset All {IDENTIFIER}', flush=True)
    if dry_run:
        print('Dry run; nothing changed.')
        return
    check_stopped(root)
    if platform == 'darwin':
        # Use the per-app reset. Never clear another app's privacy decisions.
        subprocess.run(['tccutil', 'reset', 'All', IDENTIFIER], check=True)
        for path in existing:
            if path.parent == home / 'Library/LaunchAgents':
                result = subprocess.run(['launchctl', 'list', path.stem], capture_output=True)
                if result.returncode == 0:
                    subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}', str(path)], check=True)
        preferences = f'{IDENTIFIER}.plist'
        if any(path.name == preferences for path in existing):
            # Removing a plist alone can leave cfprefsd's in-memory copy behind.
            subprocess.run(['defaults', 'delete', IDENTIFIER], check=True)
    for path in existing:
        remove(path)
    for path in server_data:
        # Keep the addon loadable, but remove all downloaded prices.
        if path.is_symlink():
            path.unlink()
        path.write_text(STUB)
    print('Local Goldbook data cleared. Start Goldbook and WoW to test setup again.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='Show the reset without changing anything')
    parser.add_argument('--wow', action='append', type=Path, default=[], help='Additional WoW installation to reset')
    args = parser.parse_args()
    try:
        reset(Path.home(), sys.platform, ROOT,
              [path.expanduser().absolute() for path in args.wow], args.dry_run)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Reset failed: {error}\n')


if __name__ == '__main__':
    main()
