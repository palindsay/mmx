#!/usr/bin/env python3
"""Capture portable performance evidence; hosted observations are not acceptance.

The kernel's strict comparison remains available, but a >20% shift on a shared
runner is recorded rather than treated as an approved release budget. Invalid
reports, failed correctness checks, or failed native execution fail this tool.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {'Linux': 'linux', 'Darwin': 'macos', 'Windows': 'windows'}


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def run_logged(arguments, cwd, output, name, *, allowed=(0,), stdout_file=None):
    """Use argument arrays and explicit UTF-8 files on every desktop platform."""
    command = [str(argument) for argument in arguments]
    log = output / (name + '.log')
    print(f'{name}: {command[0]}', flush=True)
    with log.open('w', encoding='utf-8') as errors:
        errors.write(json.dumps({'argv': command, 'cwd': str(cwd)}) + '\n')
        errors.flush()
        if stdout_file is None:
            result = subprocess.run(command, cwd=cwd, stdout=errors, stderr=errors, check=False)
        else:
            with stdout_file.open('w', encoding='utf-8') as stream:
                result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=errors, check=False)
    if result.returncode not in allowed:
        raise RuntimeError(f'{name} exited {result.returncode}; see {log.name}')
    return result.returncode


def executable(name):
    result = shutil.which(name)
    if result is None:
        raise RuntimeError(f'Required executable not found: {name}')
    return result


def revision():
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def validate_ui_report(report, *, host_id, expected_revision):
    if not isinstance(report, dict):
        raise ValueError('UI report must be a JSON object')
    for field in ('host', 'runtime', 'provenance', 'workload', 'idle500ms',
                  'reduce', 'cancelReduceOnFirstWorkerHeartbeat'):
        if not isinstance(report.get(field), dict):
            raise ValueError(f'Missing UI report object: {field}')
    if report.get('schemaVersion') != 2:
        raise ValueError('UI schema 2 with raw interval samples is required')
    if report.get('host', {}).get('id') != host_id:
        raise ValueError('UI host identity differs from this capture')
    if report.get('runtime', {}).get('buildMode') != 'profile':
        raise ValueError('UI capture must use the native profile build')
    if report.get('provenance', {}).get('gitRevision') != expected_revision:
        raise ValueError('UI source revision differs from this capture')
    harness = report['provenance'].get('harnessVersion', 2)
    if type(harness) is not int or harness not in (2, 3):
        raise ValueError('Unsupported UI harness version')
    workload = report.get('workload', {})
    if (workload.get('faces') != 100352 or workload.get('percentage') != .5 or
            workload.get('samples') != 1 or workload.get('operatorWarmups') != 0 or
            type(workload.get('outputFaces')) is not int or
            not 0 < workload['outputFaces'] < workload['faces']):
        raise ValueError('Unexpected native UI workload')
    for phase in ('idle500ms', 'reduce', 'cancelReduceOnFirstWorkerHeartbeat'):
        value = report.get(phase, {})
        if harness >= 3:
            renderer = value.get('rendererAtCompletion')
            if (not isinstance(renderer, dict) or
                    renderer.get('preference') not in ('auto', 'cpu', 'gpu') or
                    renderer.get('backend') not in ('CPU', 'CPU fallback', 'GPU (wgpu)', 'wgpu software adapter') or
                    type(renderer.get('hardwareAccelerated')) is not bool or
                    renderer['hardwareAccelerated'] != (renderer['backend'] == 'GPU (wgpu)') or
                    not isinstance(renderer.get('diagnostic'), str)):
                raise ValueError(f'Missing or inconsistent renderer capability: {phase}')
        elapsed = value.get('operationCompletionMs')
        if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed <= 0:
            raise ValueError(f'Invalid {phase} duration')
        for metric in ('heartbeatIntervals', 'heartbeatIntervalsDuringWorker',
                       'postFrameIntervals', 'postFrameIntervalsDuringWorker'):
            distribution = value.get(metric, {})
            if not isinstance(distribution, dict):
                raise ValueError(f'Missing raw distribution: {phase}/{metric}')
            raw = distribution.get('samplesMicroseconds')
            if (not isinstance(raw, list) or
                    any(type(sample) is not int or sample < 0 for sample in raw) or
                    type(distribution.get('samples')) is not int or
                    distribution.get('samples') != len(raw)):
                raise ValueError(f'Missing or invalid raw samples: {phase}/{metric}')
            if phase == 'reduce' and not raw:
                raise ValueError(f'No UI progress observed: {metric}')
            if raw:
                ordered = sorted(raw)
                expected = {
                    'medianMs': ordered[math.ceil((len(raw) - 1) * .5)] / 1000,
                    'p95Ms': ordered[math.ceil((len(raw) - 1) * .95)] / 1000,
                    'maxMs': ordered[-1] / 1000,
                }
                for key, expected_value in expected.items():
                    actual = distribution.get(key)
                    if (type(actual) not in (int, float) or not math.isfinite(actual) or
                            not math.isclose(actual, expected_value, abs_tol=1e-9)):
                        raise ValueError(f'Raw UI samples disagree with {phase}/{metric}/{key}')
    cancelled = report['cancelReduceOnFirstWorkerHeartbeat'].get('requestToOperationCompletionMs')
    if (type(cancelled) not in (int, float) or not math.isfinite(cancelled) or cancelled < 0):
        raise ValueError('Missing completed cancellation measurement')


def capture_kernel(options, output, context):
    dart = executable('dart')
    package = ROOT / 'packages/mmx_core'
    run_logged([dart, 'pub', 'get'], package, output, 'kernel-dependencies')
    with tempfile.TemporaryDirectory(prefix='mmx-performance-build-') as build:
        binary = Path(build) / ('benchmark.exe' if options.platform == 'windows' else 'benchmark')
        run_logged([dart, 'compile', 'exe', 'tool/performance.dart', '-o', binary],
                   package, output, 'kernel-compile')
        for number in (1, 2):
            run_logged([binary, '--host-id=' + options.host_id], package, output,
                       f'kernel-{number}', stdout_file=output / f'kernel-{number}.json')
        comparison = output / 'kernel-comparison.json'
        code = run_logged([binary, '--baseline=' + str(output / 'kernel-1.json'),
                           '--compare=' + str(output / 'kernel-2.json')], package, output,
                          'kernel-comparison', allowed=(0, 1), stdout_file=comparison)
        result = read_json(comparison)
        if result.get('passed') != (code == 0):
            raise ValueError('Kernel comparison result disagrees with its exit code')
        context['kernelComparisonExitCode'] = code
        context['kernelInterpretation'] = 'same-job repeatability observation; not release acceptance'


def capture_ui(options, output, context):
    flutter = executable('flutter')
    application = ROOT / 'apps/mmx_studio'
    run_logged([flutter, 'pub', 'get'], application, output, 'ui-dependencies')
    versions = subprocess.check_output([flutter, '--version', '--machine'], cwd=ROOT, text=True)
    toolchain = json.loads(versions)
    write_json(output / 'flutter-toolchain.json', toolchain)
    current = output / 'ui-current.json'
    command = [flutter, 'drive', '--profile', '--no-pub', '-d', options.platform,
               '--driver=test_driver/desktop_performance_driver.dart',
               '--target=integration_test/desktop_performance.dart',
               '--dart-define=MMX_PERF_HOST_ID=' + options.host_id,
               '--dart-define=MMX_PERF_TOOLCHAIN=Flutter-' + toolchain['frameworkVersion'],
               '--dart-define=MMX_PERF_REVISION=' + context['gitRevision'],
               '--dart-define=MMX_PERF_REPORT=' + str(current)]
    if options.platform == 'linux' and not os.environ.get('DISPLAY'):
        command = [executable('xvfb-run'), '-a'] + command
    previous = None
    for number in range(1, options.ui_samples + 1):
        current.unlink(missing_ok=True)
        run_logged(command, application, output, f'ui-profile-{number:02d}')
        report = read_json(current)
        validate_ui_report(report, host_id=options.host_id,
                           expected_revision=context['gitRevision'])
        if previous is not None:
            for key in ('host', 'runtime', 'workload'):
                # Xvfb may assign a different display number to each process.
                before, after = dict(previous[key]), dict(report[key])
                if key == 'host':
                    before.pop('displayEnvironment', None)
                    after.pop('displayEnvironment', None)
                if before != after:
                    raise ValueError(f'UI capture configuration changed between samples: {key}')
        current.replace(output / f'ui-profile-{number:02d}.json')
        previous = report
    context['uiCapturesCompleted'] = options.ui_samples


def summarize(output, context):
    lines = ['# Performance observations', '',
             f"Environment: `{context['environment']}`; platform: `{context['platform']}`.",
             f"Revision: `{context['gitRevision']}`; host label: `{context['hostId']}`.",
             '', '**Release-host acceptance: pending designated hosts, representative interactive '
             'workloads, and approved budgets.**', '',
             'Hosted jobs record observations. Job success means valid evidence, topology/UI '
             'progress/cancellation checks, and native execution; it does not approve latency '
             'or memory budgets.', '']
    first, second = output / 'kernel-1.json', output / 'kernel-2.json'
    comparison = output / 'kernel-comparison.json'
    if first.exists() and second.exists() and comparison.exists():
        try:
            baseline, candidate, changes = map(read_json, (first, second, comparison))
            lines.extend(['## Kernel AOT', '',
                          '| Case | Capture 1 median (ms) | Capture 2 median (ms) | Change |',
                          '|---|---:|---:|---:|'])
            for name, case in baseline['cases'].items():
                change = changes['medianChangePercent'][name]
                lines.append(f"| {name} | {case['medianMicroseconds'] / 1000:.3f} | "
                             f"{candidate['cases'][name]['medianMicroseconds'] / 1000:.3f} | "
                             f'{change:+.2f}% |')
            lines.extend(['', 'Cases exceeding the existing 20% comparison threshold: ' +
                          (', '.join(changes['regressions']) or 'none') +
                          '. On these observational captures this is recorded, not a release gate.', ''])
        except (ValueError, KeyError, TypeError):
            lines.extend(['Kernel evidence is incomplete; inspect raw reports and logs.', ''])
    reports = [read_json(path) for path in sorted(output.glob('ui-profile-*.json'))]
    if reports:
        completion = [item['reduce']['operationCompletionMs'] for item in reports]
        cancellation = [item['cancelReduceOnFirstWorkerHeartbeat']['requestToOperationCompletionMs']
                        for item in reports]
        lines.extend(['## Native UI profile', '',
                      f'{len(reports)} independent cold-process captures; all interval samples '
                      'are retained in the raw JSON.', '',
                      '| Duration (ms) | Minimum | Median | Maximum |',
                      '|---|---:|---:|---:|'])
        for name, samples in [('Reduce completion', completion), ('Cancellation completion', cancellation)]:
            lines.append(f'| {name} | {min(samples):.3f} | {statistics.median(samples):.3f} | '
                         f'{max(samples):.3f} |')
        lines.extend(['', 'UI timers and framework post-frame callbacks measure UI-isolate progress, '
                      'not physical presentation FPS. RSS includes launch/setup and all isolates; '
                      'no memory budget is asserted.', ''])
    if context['errors']:
        lines.extend(['## Capture failures', ''] + ['- ' + error for error in context['errors']])
    (output / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=PLATFORMS.values())
    parser.add_argument('--host-id', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--runner-label', default='local')
    parser.add_argument('--environment', choices=('github-hosted-observational', 'local-observational'),
                        default='local-observational')
    parser.add_argument('--ui-samples', type=int, choices=(1, 3, 5), default=3)
    parser.add_argument('--phase', choices=('all', 'kernel', 'ui'), default='all')
    options = parser.parse_args(argv)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', options.host_id):
        parser.error('host-id must be a non-sensitive 1–80 character machine label')
    if PLATFORMS.get(platform.system()) != options.platform:
        parser.error('the requested platform must match the native host')
    output = options.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('output must be empty; preserve previous evidence rather than overwrite it')
    output.mkdir(parents=True, exist_ok=True)
    context = {
        'schema': 1,
        'startedAtUtc': datetime.now(timezone.utc).isoformat(),
        'gitRevision': revision(),
        'gitStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
        'environment': options.environment,
        'platform': options.platform,
        'runnerLabel': options.runner_label,
        'hostId': options.host_id,
        'system': platform.platform(),
        'architecture': platform.machine(),
        'github': {name: os.environ.get(name) for name in (
            'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA',
            'GITHUB_EVENT_NAME', 'RUNNER_OS', 'RUNNER_ARCH', 'ImageOS', 'ImageVersion')},
        'uiCapturesRequested': options.ui_samples,
        'releaseAcceptance': 'pending-designated-hosts-and-approved-budgets',
        'errors': [],
    }
    write_json(output / 'capture-context.json', context)
    for phase, capture in [('kernel', capture_kernel), ('ui', capture_ui)]:
        if options.phase not in ('all', phase):
            continue
        try:
            capture(options, output, context)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError, RuntimeError) as error:
            context['errors'].append(f'{phase}: {error}')
            print(context['errors'][-1], file=sys.stderr, flush=True)
        write_json(output / 'capture-context.json', context)
    context['completedAtUtc'] = datetime.now(timezone.utc).isoformat()
    context['status'] = 'failed' if context['errors'] else 'captured'
    write_json(output / 'capture-context.json', context)
    summarize(output, context)
    files = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(output.iterdir()) if path.is_file()}
    write_json(output / 'artifact-sha256.json', files)
    return 1 if context['errors'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
