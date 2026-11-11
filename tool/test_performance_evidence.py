"""Performance evidence integrity and portable orchestration checks; no builds."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'performance_evidence', Path(__file__).with_name('performance_evidence.py'))
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def ui_report():
    distribution = {'samples': 3, 'samplesMicroseconds': [16000, 18000, 17000],
                    'medianMs': 17, 'p95Ms': 18, 'maxMs': 18}
    phase = {'operationCompletionMs': 500, **{
        key: copy.deepcopy(distribution) for key in (
            'heartbeatIntervals', 'heartbeatIntervalsDuringWorker',
            'postFrameIntervals', 'postFrameIntervalsDuringWorker')}}
    return {'schemaVersion': 2, 'host': {'id': 'test-host'},
            'runtime': {'buildMode': 'profile'},
            'provenance': {'gitRevision': 'test-revision'},
            'workload': {'faces': 100352, 'outputFaces': 50176, 'percentage': .5,
                         'samples': 1, 'operatorWarmups': 0},
            'idle500ms': copy.deepcopy(phase), 'reduce': copy.deepcopy(phase),
            'cancelReduceOnFirstWorkerHeartbeat': {
                **copy.deepcopy(phase), 'requestToOperationCompletionMs': 12}}


class EvidenceTests(unittest.TestCase):
    def validate(self, report):
        evidence.validate_ui_report(report, host_id='test-host', expected_revision='test-revision')

    def test_valid_profile_samples_and_empty_idle_worker_phase(self):
        report = ui_report()
        report['idle500ms']['postFrameIntervalsDuringWorker'] = {
            'samples': 0, 'samplesMicroseconds': []}
        self.validate(report)

    def test_debug_legacy_or_wrong_source_is_rejected(self):
        for modify in (
            lambda r: r.update(schemaVersion=1),
            lambda r: r['runtime'].update(buildMode='debug'),
            lambda r: r['host'].update(id='another-host'),
            lambda r: r['provenance'].update(gitRevision='another-revision'),
        ):
            report = ui_report()
            modify(report)
            with self.assertRaises(ValueError):
                self.validate(report)

    def test_renderer_evidence_distinguishes_software_and_hardware(self):
        report = ui_report()
        report['provenance']['harnessVersion'] = 3
        with self.assertRaisesRegex(ValueError, 'renderer capability'):
            self.validate(report)
        for phase in ('idle500ms', 'reduce', 'cancelReduceOnFirstWorkerHeartbeat'):
            report[phase]['rendererAtCompletion'] = {
                'preference': 'auto', 'backend': 'wgpu software adapter',
                'hardwareAccelerated': False, 'diagnostic': 'software Vulkan'}
        self.validate(report)
        report['reduce']['rendererAtCompletion']['hardwareAccelerated'] = True
        with self.assertRaisesRegex(ValueError, 'renderer capability'):
            self.validate(report)
        report['reduce']['rendererAtCompletion']['backend'] = 'GPU (wgpu)'
        self.validate(report)

    def test_stale_or_fabricated_interval_summaries_are_rejected(self):
        for invalid in (float('nan'), 99, None, True):
            report = ui_report()
            report['reduce']['postFrameIntervals']['p95Ms'] = invalid
            with self.assertRaises(ValueError):
                self.validate(report)
        report = ui_report()
        report['reduce']['heartbeatIntervals']['samplesMicroseconds'] = [0, -1, 1000]
        with self.assertRaises(ValueError):
            self.validate(report)

    def test_missing_raw_samples_or_worker_progress_is_rejected(self):
        report = ui_report()
        report['reduce']['heartbeatIntervalsDuringWorker'] = {'samples': 0, 'samplesMicroseconds': []}
        with self.assertRaises(ValueError):
            self.validate(report)
        for invalid in ([], {'schemaVersion': 2}, None):
            with self.assertRaises(ValueError):
                self.validate(invalid)

    def test_missing_or_invalid_cancellation_is_rejected(self):
        report = ui_report()
        report['cancelReduceOnFirstWorkerHeartbeat']['requestToOperationCompletionMs'] = -1
        with self.assertRaises(ValueError):
            self.validate(report)

    def test_subprocess_logging_preserves_spaces_and_failure_output(self):
        with tempfile.TemporaryDirectory(prefix='mmx evidence ') as scratch:
            output = Path(scratch)
            code = evidence.run_logged(
                [sys.executable, '-c', 'import sys; print(sys.argv[1]); print("problem",file=sys.stderr); sys.exit(7)',
                 'value with spaces'], output, output, 'sample', allowed=(7,),
                stdout_file=output / 'sample.json')
            self.assertEqual(code, 7)
            self.assertEqual((output / 'sample.json').read_text().strip(), 'value with spaces')
            self.assertIn('problem', (output / 'sample.log').read_text())
            with self.assertRaises(RuntimeError):
                evidence.run_logged([sys.executable, '-c', 'raise SystemExit(2)'], output, output, 'failure')

    def test_failed_kernel_still_attempts_ui_and_preserves_diagnostics(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / 'evidence'
            with patch.object(evidence, 'revision', return_value='test-revision'), \
                 patch.object(evidence.subprocess, 'check_output', return_value=''), \
                 patch.object(evidence, 'capture_kernel', side_effect=RuntimeError('broken kernel')), \
                 patch.object(evidence, 'capture_ui') as ui:
                result = evidence.main(['--platform', evidence.PLATFORMS[evidence.platform.system()],
                                        '--host-id', 'test-host', '--output', str(output)])
            self.assertEqual(result, 1)
            ui.assert_called_once()
            context = evidence.read_json(output / 'capture-context.json')
            self.assertEqual(context['status'], 'failed')
            self.assertIn('broken kernel', context['errors'][0])
            self.assertIn('pending', context['releaseAcceptance'])
            self.assertTrue((output / 'artifact-sha256.json').exists())
            self.assertIn('Capture failures', (output / 'summary.md').read_text())

    def test_existing_evidence_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch)
            existing = output / 'capture-context.json'
            existing.write_text('preserve me')
            with self.assertRaises(SystemExit) as error:
                evidence.main(['--platform', evidence.PLATFORMS[evidence.platform.system()],
                               '--host-id', 'test-host', '--output', str(output)])
            self.assertEqual(error.exception.code, 2)
            self.assertEqual(existing.read_text(), 'preserve me')

    def test_summary_retains_hosted_regression_as_observation(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch)
            for number, median in ((1, 100), (2, 150)):
                evidence.write_json(output / f'kernel-{number}.json',
                                    {'cases': {'12k/reduce': {'medianMicroseconds': median}}})
            evidence.write_json(output / 'kernel-comparison.json',
                                {'medianChangePercent': {'12k/reduce': 50},
                                 'regressions': ['12k/reduce']})
            evidence.write_json(output / 'ui-profile-01.json', ui_report())
            evidence.summarize(output, {'environment': 'github-hosted-observational',
                                       'platform': 'linux', 'gitRevision': 'test-revision',
                                       'hostId': 'test-host', 'errors': []})
            summary = (output / 'summary.md').read_text()
            self.assertIn('+50.00%', summary)
            self.assertIn('not a release gate', summary)
            self.assertIn('pending designated hosts', summary)
            self.assertIn('1 independent cold-process captures', summary)


if __name__ == '__main__':
    unittest.main()
