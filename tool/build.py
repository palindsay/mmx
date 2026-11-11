#!/usr/bin/env python3
"""Build optimized mmx CLI and Studio bundles on Linux, Windows or macOS.

make build          Build both for this host (Dart AOT, Flutter/Rust release).
make linux          Explicit Linux host build; Windows/macOS targets work likewise.
make cli / studio   Build one component.
make test           Format check, analyze, and test both Dart packages.
make package        Build and package a portable review archive with provenance.
make native-package Also create the host's unsigned native installer.

Python-only equivalent: python3 tool/build.py [options]. Each desktop platform
must be built on its own OS with the native toolchain from QUICKSTART.md.
Artifacts: bin/builds/<platform>-<architecture>/ (keep the entire studio bundle).
Publisher signing is a separate step described in docs/RELEASE.md.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / 'packages/mmx_core'
STUDIO = ROOT / 'apps/mmx_studio'
SYSTEMS = {'Linux': 'linux', 'Windows': 'windows', 'Darwin': 'macos'}


def host_platform():
    value = SYSTEMS.get(platform.system())
    if value is None:
        raise ValueError('Supported hosts are Linux, Windows and macOS')
    return value


def build_commands(target, component='all'):
    commands = []
    if component in ('all', 'cli'):
        commands += [(CORE, ['dart', 'pub', 'get']),
                     (CORE, ['dart', 'compile', 'exe', 'bin/mmx.dart', '-o', f'mmx-{target}.exe'])]
    if component in ('all', 'studio'):
        commands += [(STUDIO, ['flutter', 'pub', 'get']),
                     (STUDIO, ['flutter', 'build', target, '--release'])]
    return commands


def run(command, cwd=ROOT, *, dry=False, output=None):
    print(f'[{cwd.relative_to(ROOT) or Path(".")}] {subprocess.list2cmdline([str(v) for v in command])}', flush=True)
    if dry:
        return
    executable = shutil.which(str(command[0]))
    if not executable:
        raise ValueError(f'Missing {command[0]} on PATH; see QUICKSTART.md')
    subprocess.run([executable, *map(str, command[1:])], cwd=cwd, check=True,
                   stdout=output, text=True)


def verify(dry=False):
    for directory, runtime in ((CORE, 'dart'), (STUDIO, 'flutter')):
        run([runtime, 'pub', 'get'], directory, dry=dry)
        directories = ['lib', 'test', 'bin'] if directory == CORE else ['lib', 'test', 'integration_test', 'test_driver']
        run(['dart', 'format', '--output=none', '--set-exit-if-changed', *directories], directory, dry=dry)
        run([runtime, 'analyze'], directory, dry=dry)
        run([runtime, 'test'], directory, dry=dry)


def bundle_path(target):
    if target == 'macos':
        candidates = list((STUDIO / 'build/macos/Build/Products/Release').glob('*.app'))
    elif target == 'windows':
        candidates = list((STUDIO / 'build/windows').glob('*/runner/Release'))
    else:
        candidates = list((STUDIO / 'build/linux').glob('*/release/bundle'))
    if len(candidates) != 1:
        raise ValueError(f'Expected one {target} release bundle; found {len(candidates)}. Remove stale builds for other architectures first.')
    return candidates[0]


def stage(target, component):
    arch = platform.machine().lower()
    destination = ROOT / 'bin/builds' / f'{target}-{arch}'
    destination.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError('Refusing to stage over a symlink')
    if component in ('all', 'cli'):
        name = 'mmx.exe' if target == 'windows' else 'mmx'
        temporary = destination / f'.{name}.tmp'
        shutil.copy2(CORE / f'mmx-{target}.exe', temporary)
        os.replace(temporary, destination / name)
    if component in ('all', 'studio'):
        source = bundle_path(target)
        name = 'mmx_studio.app' if target == 'macos' else 'studio'
        with tempfile.TemporaryDirectory(prefix='.stage-', dir=destination) as staging:
            candidate = Path(staging) / name
            shutil.copytree(source, candidate, symlinks=True)
            final = destination / name
            previous = Path(staging) / 'previous'
            if final.is_symlink():
                raise ValueError('Refusing to replace a symlink bundle')
            if final.exists():
                final.rename(previous)
            try:
                candidate.rename(final)
            except OSError:
                if previous.exists():
                    previous.rename(final)
                raise
    print(f'Optimized artifacts: {destination}', flush=True)
    return destination


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--platform', choices=('auto', 'linux', 'windows', 'macos'), default='auto')
    parser.add_argument('--component', choices=('all', 'cli', 'studio'), default='all')
    parser.add_argument('--verify', action='store_true', help='run repository checks instead of building')
    parser.add_argument('--package', action='store_true', help='build both and create a portable archive')
    parser.add_argument('--native', action='store_true', help='also produce an unsigned installer; requires --package')
    parser.add_argument('--dry-run', action='store_true', help='print commands without modifying outputs')
    args = parser.parse_args(argv)
    if sys.version_info < (3, 11):
        parser.error('Build and packaging require Python 3.11 or newer')
    host = host_platform()
    arch = platform.machine().lower()
    supported = {'linux': {'x86_64', 'amd64'}, 'windows': {'amd64', 'x86_64'}, 'macos': {'arm64', 'aarch64', 'x86_64'}}
    if arch not in supported[host]:
        parser.error(f'{host}/{arch} is not in the supported desktop build matrix')
    target = host if args.platform == 'auto' else args.platform
    if target != host:
        parser.error(f'{target} desktop requires a {target} host; this host is {host}. Use the native CI matrix for other platforms.')
    if args.native and not args.package:
        parser.error('--native requires --package')
    if args.package and args.component != 'all':
        parser.error('--package requires both components')
    if args.verify and args.package:
        parser.error('Run verification and packaging as separate commands')
    if args.verify:
        verify(args.dry_run)
        return 0
    for directory, command in build_commands(target, args.component):
        run(command, directory, dry=args.dry_run)
    if not args.dry_run:
        stage(target, args.component)
    if args.component == 'all':
        run([sys.executable, 'tool/package_release.py', target, '--record-build'], dry=args.dry_run)
    if args.package:
        if not args.dry_run:
            with (ROOT / 'toolchain.txt').open('w', encoding='utf-8') as stream:
                run(['flutter', '--version'], output=stream)
                run(['rustc', '+1.99.1', '--version'], output=stream)
                run(['git', 'rev-parse', 'HEAD'], output=stream)
            with (ROOT / 'dependencies.json').open('w', encoding='utf-8') as stream:
                run(['flutter', 'pub', 'deps', '--json'], STUDIO, output=stream)
            json.loads((ROOT / 'dependencies.json').read_text(encoding='utf-8'))
        run([sys.executable, 'tool/collect_licenses.py'], dry=args.dry_run)
        run([sys.executable, 'tool/package_release.py', target, *(['--native'] if args.native else [])], dry=args.dry_run)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Build failed: {error}', file=sys.stderr)
        sys.exit(1)
