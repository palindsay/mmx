"""Artifact content and deterministic-container checks; no builds required."""
import hashlib
import os
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
import tarfile

spec = importlib.util.spec_from_file_location('package_release', Path(__file__).with_name('package_release.py'))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class PackageTests(unittest.TestCase):
    def test_receipt_rejects_changed_source_binary_and_dirty_signing(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            bundle = root / packaging.BUNDLES['linux']
            bundle.mkdir(parents=True)
            (bundle / 'mmx_studio').write_bytes(b'app')
            (bundle / 'lib').mkdir()
            (bundle / 'lib/libmmx_gpu.so').write_bytes(b'native-renderer')
            notices = bundle / 'data/native-licenses'
            notices.mkdir(parents=True)
            (notices / 'index.json').write_text('{"packages": []}')
            cli = root / 'packages/mmx_core/mmx-linux.exe'
            cli.parent.mkdir(parents=True)
            cli.write_bytes(b'cli')
            (root / 'source.dart').write_text('original source')
            def git_output(command, **kwargs):
                if command[1] == 'rev-parse':
                    return 'a' * 40
                if command[1] == 'ls-files':
                    return b'source.dart\0'
                if command[1] == 'status':
                    return b''
                self.fail(command)
            with mock.patch.object(packaging, 'ROOT', root), mock.patch.object(
                    packaging.subprocess, 'check_output', side_effect=git_output):
                with self.assertRaisesRegex(RuntimeError, 'Missing build receipt'):
                    packaging.validate_build_receipt('linux', '0.1.0')
                receipt_path = packaging.record_build_receipt('linux', '0.1.0')
                packaging.validate_build_receipt('linux', '0.1.0', require_clean=True)
                cli.write_bytes(b'changed executable')
                with self.assertRaisesRegex(RuntimeError, 'Build outputs changed'):
                    packaging.validate_build_receipt('linux', '0.1.0')
                cli.write_bytes(b'cli')
                (root / 'source.dart').write_text('changed source')
                with self.assertRaisesRegex(RuntimeError, 'sourceDigest'):
                    packaging.validate_build_receipt('linux', '0.1.0')
                (root / 'source.dart').write_text('original source')
                receipt = json.loads(receipt_path.read_text())
                receipt['dirty'] = True
                receipt_path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(RuntimeError, 'clean source tree'):
                    packaging.validate_build_receipt('linux', '0.1.0', require_clean=True)

    def test_receipt_requires_native_renderer_and_dependency_notices(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            bundle = root / packaging.BUNDLES['windows']
            bundle.mkdir(parents=True)
            cli = root / 'packages/mmx_core/mmx-windows.exe'
            cli.parent.mkdir(parents=True)
            cli.write_bytes(b'cli')
            with mock.patch.object(packaging, 'ROOT', root):
                with self.assertRaisesRegex(RuntimeError, 'Native renderer missing'):
                    packaging.build_input_manifest('windows')
                (bundle / 'mmx_gpu.dll').write_bytes(b'renderer')
                with self.assertRaisesRegex(RuntimeError, 'dependency notices missing'):
                    packaging.build_input_manifest('windows')
                notices = bundle / 'data/native-licenses'
                notices.mkdir(parents=True)
                (notices / 'index.json').write_text('{"packages": []}')
                files = packaging.build_input_manifest('windows')
                self.assertTrue(any(name.endswith('mmx_gpu.dll') for name in files))

    def test_build_receipt_rejects_repository_only_model_assets(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            model = root / 'Contents/Frameworks/App.framework/Resources/flutter_assets/assets/models/research.obj'
            model.parent.mkdir(parents=True)
            model.write_bytes(b'not distributable')
            with self.assertRaisesRegex(RuntimeError, 'Repository-only model assets'):
                packaging.validate_release_bundle(root)

    def test_windows_signs_payload_before_manifest_and_installer_in_compiler(self):
        with tempfile.TemporaryDirectory(prefix='mmx signing ') as scratch:
            stage = Path(scratch) / 'stage'
            (stage / 'studio').mkdir(parents=True)
            for path in (stage / 'mmx.exe', stage / 'studio/mmx_studio.exe',
                         stage / 'studio/mmx_gpu.dll'):
                path.write_bytes(b'unsigned')
            signed_output = Path(scratch) / 'mmx-0.1.0-windows-signed.exe'
            commands = []
            def run(command, **kwargs):
                commands.append(command)
                if command[0] == 'fake-iscc':
                    signed_output.write_bytes(b'signed installer and uninstaller')
                else:
                    path = Path(command[-1])
                    path.write_bytes(path.read_bytes() + b'-signed')
            with mock.patch.object(packaging, 'windows_sign_command', return_value=[
                    'C:/Program Files/PowerShell/pwsh.exe', '-File', 'C:/source $test/sign.ps1', '-NoChecksum']), mock.patch.object(
                    packaging.subprocess, 'run', side_effect=run), mock.patch.dict(os.environ, {'ISCC_PATH': 'fake-iscc'}):
                packaging.sign_windows_payload(stage)
                manifest = packaging.tree_manifest(stage)
                self.assertEqual(manifest['mmx.exe']['sha256'], hashlib.sha256(b'unsigned-signed').hexdigest())
                self.assertEqual(manifest['studio/mmx_gpu.dll']['sha256'], hashlib.sha256(b'unsigned-signed').hexdigest())
                result = packaging.native_installer(stage, Path(scratch), 'windows', '0.1.0', 0, sign_windows=True)
            self.assertEqual(result, signed_output)
            self.assertEqual(len(commands), 4)
            self.assertIn('/DSigned', commands[-1])
            self.assertIn('/Smmx=$qC:/Program Files/PowerShell/pwsh.exe$q $q-File$q $qC:/source $$test/sign.ps1$q $q-NoChecksum$q -Paths $f', commands[-1])
            self.assertEqual(result.with_suffix('.exe.sha256').read_text(),
                             f'{packaging.digest_file(result)}  {result.name}\n')

    def test_windows_signing_fails_without_credentials(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'MMX_CERT_THUMBPRINT'):
                packaging.windows_sign_command()

    def test_portable_is_repeatable_and_preserves_executable(self):
        for system in ('linux', 'windows'):
            with self.subTest(system=system), tempfile.TemporaryDirectory() as scratch:
                directory = Path(scratch)
                stage = directory / 'mmx-test'
                stage.mkdir()
                executable = stage / 'mmx'
                executable.write_bytes(b'example binary')
                executable.chmod(0o755)
                (stage / 'LICENSE').write_text('license\n')
                first = packaging.portable(stage, directory / 'first', system, 1700000000)
                second = packaging.portable(stage, directory / 'second', system, 1700000000)
                self.assertEqual(packaging.digest_file(first), packaging.digest_file(second))
                if system == 'linux':
                    with tarfile.open(first) as archive:
                        if os.name != 'nt':
                            self.assertEqual(archive.getmember('mmx-test/mmx').mode, 0o755)
                        self.assertEqual(archive.extractfile('mmx-test/mmx').read(), b'example binary')
                else:
                    with zipfile.ZipFile(first) as archive:
                        self.assertEqual(archive.read('mmx-test/mmx'), b'example binary')
                self.assertTrue(first.with_name(first.name + '.sha256').is_file())

    def test_manifest_records_content_and_links(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / 'a').write_bytes(b'abc')
            self.assertEqual(packaging.tree_manifest(root)['a']['sha256'], hashlib.sha256(b'abc').hexdigest())

    def test_installed_manifest_detects_corruption_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory(prefix='mmx package ') as scratch:
            root = Path(scratch)
            payload = root / 'binary'
            payload.write_bytes(b'original executable')
            manifest = root / 'provenance.json'
            data = {'files': packaging.tree_manifest(root)}
            manifest.write_text(json.dumps(data), encoding='utf-8')
            command = [sys.executable, str(Path(__file__).with_name('verify_manifest.py')),
                       str(manifest), '--root', str(root)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            payload.write_bytes(b'corrupt executable!')
            corrupt = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(corrupt.returncode, 0)
            self.assertIn('Content mismatch', corrupt.stderr)
            data['files'] = {'../outside': {'sha256': '0' * 64, 'size': 0}}
            manifest.write_text(json.dumps(data), encoding='utf-8')
            unsafe = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertIn('Invalid manifest path', unsafe.stderr)


@unittest.skipUnless(os.name != 'nt' and shutil.which('bash'), 'macOS shell harness needs a POSIX host')
class MacSigningTests(unittest.TestCase):
    """Run the real orchestration with local fake platform commands, no signing."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='mmx signer fixture ')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        repo = Path(__file__).resolve().parent.parent
        for name in ('tool/package_release.py', 'tool/release/sign_macos.sh',
                     'apps/mmx_studio/macos/Runner/Release.entitlements', 'LICENSE', 'NOTICE'):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo / name, destination)
        (self.root / 'apps/mmx_studio/pubspec.yaml').write_text('version: 0.1.0+1\n')
        (self.root / 'source.dart').write_text('reviewed source')
        self.cli = self.root / 'packages/mmx_core/mmx-macos.exe'
        self.cli.parent.mkdir(parents=True)
        self.cli.write_bytes(b'cli')
        app = self.root / packaging.BUNDLES['macos'] / 'mmx_studio.app'
        for relative in ('Contents/MacOS/mmx_studio', 'Contents/Frameworks/Plugin.framework/Plugin',
                         'Contents/Frameworks/libmmx_gpu.dylib'):
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'code')
        notices = app / 'Contents/Resources/native-licenses/arm64'
        notices.mkdir(parents=True)
        (notices / 'index.json').write_text('{"packages": []}')
        (self.root / 'tool/collect_licenses.py').write_text(
            "from pathlib import Path\nPath(__file__).resolve().parent.parent.joinpath('THIRD_PARTY_LICENSES.txt').write_text('licenses')\n")
        command_dir = self.root / 'fake commands'
        command_dir.mkdir()
        stub = '''import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['MMX_FIXTURE_LOG'], 'a') as output:
    output.write(json.dumps([name, *args]) + '\\n')
if name == 'git':
    if args[0] == 'rev-parse': print('a' * 40)
    elif args[0] == 'ls-files': sys.stdout.buffer.write(b'source.dart\\0apps/mmx_studio/pubspec.yaml\\0')
    elif args[0] == 'show': print('1700000000')
elif name == 'ditto': shutil.copytree(args[0], args[1], symlinks=True)
elif name == 'flutter': print('{}' if 'deps' in args else 'Flutter fixture')
elif name == 'codesign' and '--verify' not in args:
    target = pathlib.Path(args[-1])
    if target.is_dir():
        target = target / '_CodeSignature/CodeResources'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'fixture signature')
    else: target.write_bytes(target.read_bytes() + b'-signed')
elif name == 'pkgbuild':
    if '--analyze' in args:
        pathlib.Path(args[-1]).write_bytes(plistlib.dumps([{'BundleIsRelocatable': True}]))
    else:
        root = pathlib.Path(args[args.index('--root') + 1])
        shutil.copytree(root, os.environ['MMX_FIXTURE_CAPTURE'])
        components = pathlib.Path(args[args.index('--component-plist') + 1])
        assert not plistlib.loads(components.read_bytes())[0]['BundleIsRelocatable']
        pathlib.Path(args[-1]).write_bytes(b'signed package')
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        print(json.dumps({'id': 'fixture-submission', 'status': os.environ.get('MMX_FIXTURE_NOTARY', 'Accepted')}))
    elif args[:2] == ['notarytool', 'log']:
        pathlib.Path(args[-1]).write_text(json.dumps({'status': 'Accepted', 'issues': []}))
    elif args[:2] == ['stapler', 'staple']:
        target = pathlib.Path(args[-1])
        target.write_bytes(target.read_bytes() + b'-stapled')
    elif args[:2] == ['stapler', 'validate'] and os.environ.get('MMX_FIXTURE_BAD_TICKET'):
        sys.exit(2)
'''
        for name in ('git', 'ditto', 'flutter', 'codesign', 'pkgbuild', 'xcrun', 'pkgutil', 'spctl'):
            command = command_dir / name
            command.write_text(f'#!{sys.executable}\n' + stub)
            command.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(command_dir) + os.pathsep + os.environ['PATH'],
                    'MMX_APP_IDENTITY': 'fixture application', 'MMX_INSTALLER_IDENTITY': 'fixture installer',
                    'MMX_NOTARY_PROFILE': 'fixture profile', 'MMX_FIXTURE_LOG': str(self.root / 'calls.jsonl'),
                    'MMX_FIXTURE_CAPTURE': str(self.root / 'captured payload')}
        result = subprocess.run([sys.executable, str(self.root / 'tool/package_release.py'),
                                 'macos', '--record-build'], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def sign(self, **environment):
        return subprocess.run(['bash', str(self.root / 'tool/release/sign_macos.sh')],
                              env={**self.env, **environment}, capture_output=True, text=True)

    def test_accepted_installer_has_post_sign_manifest_and_post_staple_checksum(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        package = self.root / 'bin/releases/mmx-0.1.0-macos-signed.pkg'
        self.assertEqual(package.read_bytes(), b'signed package-stapled')
        self.assertEqual(package.with_suffix('.pkg.sha256').read_text(),
                         f'{packaging.digest_file(package)}  {package.name}\n')
        payload = self.root / 'captured payload'
        manifest_path = payload / 'usr/local/share/mmx/provenance.json'
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest['version'], '0.1.0')
        self.assertEqual(manifest['manifestRoot'], '/')
        self.assertFalse(manifest['dirty'])
        self.assertTrue(manifest['codeSigned'])
        self.assertEqual(len(manifest['sourceDigest']), 64)
        self.assertEqual(manifest['files']['usr/local/bin/mmx']['sha256'], hashlib.sha256(b'cli-signed').hexdigest())
        self.assertEqual(manifest['files']['Applications/mmx Studio.app/Contents/Frameworks/libmmx_gpu.dylib']['sha256'],
                         hashlib.sha256(b'code-signed').hexdigest())
        self.assertEqual(manifest['buildReceiptSha256'], packaging.digest_file(
            payload / 'usr/local/share/mmx/build-receipt.json'))
        verified = subprocess.run([sys.executable, str(Path(__file__).with_name('verify_manifest.py')),
                                   str(manifest_path), '--root', str(payload)], capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertTrue(any(call[:3] == ['xcrun', 'stapler', 'validate'] for call in calls))
        self.assertTrue(any(call[:4] == ['spctl', '--assess', '--type', 'install'] for call in calls))
        self.assertTrue(package.with_suffix('.pkg.notary-log.json').is_file())

    def test_rejected_notarization_does_not_publish_installer_or_checksum(self):
        result = self.sign(MMX_FIXTURE_NOTARY='Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Notarization was not accepted', result.stderr)
        self.assertEqual(list((self.root / 'bin/releases').glob('*.pkg*')), [])

    def test_invalid_stapled_ticket_does_not_publish_installer(self):
        result = self.sign(MMX_FIXTURE_BAD_TICKET='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.root / 'bin/releases').glob('*.pkg*')), [])

    def test_stale_build_is_rejected_before_signing(self):
        self.cli.write_bytes(b'unreviewed replacement')
        result = self.sign()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Build outputs changed', result.stderr)
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertFalse(any(call[0] == 'codesign' for call in calls))


@unittest.skipUnless(shutil.which('pwsh'), 'PowerShell available on Windows CI/signing hosts')
class WindowsSigningTests(unittest.TestCase):
    def test_signing_refreshes_checksum_after_signature_verification(self):
        with tempfile.TemporaryDirectory(prefix='mmx authenticode fixture ') as scratch:
            root = Path(scratch)
            binary = root / 'installer.exe'
            binary.write_bytes(b'unsigned')
            binary.with_suffix('.exe.sha256').write_text('stale')
            harness = root / 'fixture.ps1'
            harness.write_text('''param($Script, $Binary)
$ErrorActionPreference = 'Stop'
$env:MMX_CERT_THUMBPRINT = 'fixture'
$env:MMX_TIMESTAMP_URL = 'https://timestamp.invalid/fixture'
function Get-Command { param($Name) [pscustomobject]@{Source='MockSignTool'} }
function MockSignTool {
  if ($args[0] -eq 'sign') { [IO.File]::AppendAllText($args[-1], '-signed') }
  elseif ($args -notcontains '/tw') { throw 'Timestamp verification missing' }
  $global:LASTEXITCODE = 0
}
& $Script -Paths $Binary
''')
            signer = Path(__file__).resolve().parent / 'release/sign_windows.ps1'
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(harness), str(signer), str(binary)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(binary.read_bytes(), b'unsigned-signed')
            self.assertEqual(binary.with_suffix('.exe.sha256').read_text(),
                             f'{packaging.digest_file(binary)}  installer.exe\n')


if __name__ == '__main__':
    unittest.main()
