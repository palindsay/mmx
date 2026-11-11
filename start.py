#!/usr/bin/env python3
"""Build and run mmx Studio on the current desktop platform."""

import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--debug', action='store_true',
        help='use a debug build with hot reload instead of release mode',
    )
    parser.add_argument(
        '--build-only', action='store_true',
        help='build the desktop bundle without launching Studio',
    )
    args = parser.parse_args()
    target = {'Linux': 'linux', 'Darwin': 'macos', 'Windows': 'windows'}.get(
        platform.system()
    )
    if target is None:
        parser.exit(1, 'Studio supports Linux, macOS, and Windows. See QUICKSTART.md.\n')

    root = Path(__file__).resolve().parent
    app = root / 'apps' / 'mmx_studio'
    if not (app / 'pubspec.yaml').is_file():
        parser.exit(1, 'Keep start.py in the mmx repository root.\n')

    flutter = shutil.which('flutter')
    missing = [name for name in ('flutter', 'cargo') if shutil.which(name) is None]
    if missing:
        parser.exit(
            1, 'Missing tools on PATH: ' + ', '.join(missing)
            + '. Install the tools in QUICKSTART.md and reopen your terminal.\n',
        )

    mode = '--debug' if args.debug else '--release'
    action = ['build', target] if args.build_only else ['run', '-d', target]
    commands = [[flutter, 'pub', 'get'], [flutter, *action, mode]]
    print(f'mmx Studio: {target}, {mode[2:]} mode', flush=True)
    print(f'Project: {app}', flush=True)
    for command in commands:
        print('+ ' + subprocess.list2cmdline(command), flush=True)
        subprocess.run(command, cwd=app, check=True)
    if args.build_only:
        print('Build complete. Keep the full bundle at the path Flutter printed above.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except subprocess.CalledProcessError as error:
        print('Build/run failed. Check the output above and QUICKSTART.md.', file=sys.stderr)
        sys.exit(error.returncode if error.returncode > 0 else 128 - error.returncode)
    except OSError as error:
        print(f'Could not start the build tools: {error}', file=sys.stderr)
        sys.exit(1)
