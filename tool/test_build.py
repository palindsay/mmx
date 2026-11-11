import unittest
from io import StringIO
from unittest.mock import patch
import build


class BuildTests(unittest.TestCase):
    hosts = (('linux', 'x86_64'), ('windows', 'AMD64'),
             ('macos', 'arm64'), ('macos', 'x86_64'))

    def test_release_commands_for_each_host(self):
        for host in ('linux', 'windows', 'macos'):
            commands = [command for _, command in build.build_commands(host)]
            self.assertIn(['flutter', 'build', host, '--release'], commands)
            self.assertTrue(any(command[:3] == ['dart', 'compile', 'exe'] for command in commands))
            self.assertFalse(any('--debug' in command for command in commands))

    def test_other_host_rejected_before_running_tools(self):
        for host, arch in self.hosts:
            target = 'windows' if host != 'windows' else 'linux'
            with (self.subTest(host=host, arch=arch),
                  patch.object(build, 'host_platform', return_value=host),
                  patch.object(build.platform, 'machine', return_value=arch),
                  patch.object(build, 'run') as run,
                  patch('sys.stderr', new_callable=StringIO) as errors):
                with self.assertRaises(SystemExit) as failure:
                    build.main(['--platform', target])
                self.assertEqual(failure.exception.code, 2)
                self.assertIn(f'{target} desktop requires a {target} host', errors.getvalue())
                run.assert_not_called()

    def test_dry_run_does_not_stage_or_package_mutations(self):
        for host, arch in self.hosts:
            with (self.subTest(host=host, arch=arch),
                  patch.object(build, 'host_platform', return_value=host),
                  patch.object(build.platform, 'machine', return_value=arch),
                  patch.object(build, 'stage') as stage,
                  patch.object(build.subprocess, 'run') as run):
                self.assertEqual(build.main(['--dry-run', '--package']), 0)
                stage.assert_not_called()
                run.assert_not_called()

    def test_build_failure_propagates(self):
        for host, arch in self.hosts:
            with (self.subTest(host=host, arch=arch),
                  patch.object(build, 'host_platform', return_value=host),
                  patch.object(build.platform, 'machine', return_value=arch),
                  patch.object(build, 'run', side_effect=ValueError('missing compiler')),
                  patch.object(build, 'stage') as stage):
                with self.assertRaisesRegex(ValueError, 'missing compiler'):
                    build.main([])
                stage.assert_not_called()

    def test_cli_only_omits_flutter(self):
        commands = [command for _, command in build.build_commands('linux', 'cli')]
        self.assertTrue(commands)
        self.assertTrue(all(command[0] == 'dart' for command in commands))


if __name__ == '__main__':
    unittest.main()
