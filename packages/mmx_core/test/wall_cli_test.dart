import 'dart:convert';
import 'dart:io';

import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';
import '../tool/corpus/analytic_meshes.dart';

void main() {
  test('CLI saves verified geometry and reports the actual applied growth',
      () async {
    final directory = await Directory.systemTemp.createTemp('mmx-wall-cli-');
    try {
      final input = '${directory.path}/slab.obj';
      final slab = analyticCube()..transform(identity4()..[5] = .1);
      await MeshIO.writeFile(input, slab);
      final output = '${directory.path}/verified.obj';
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/mmx.dart',
        'solid',
        input,
        output,
        '--res',
        '24',
        '--min-thickness',
        '.5',
        '--max-growth',
        '.5',
        '--attempts',
        '6',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final lines = const LineSplitter().convert(result.stdout as String);
      final report = jsonDecode(lines.last)['wallClearance'] as Map;
      expect(report['metric'], WallThicknessCertificate.metric);
      expect(report['status'], 'passed');
      expect(report['verifiedLowerBound'], .5);
      expect(report['appliedOffset'], greaterThan(0));
      expect(report['reconstruction'], 'surface-nets');
      expect(report['reconstructionDiagnostic'], isNull);
      expect(WallThickness.certify(MeshIO.readFile(output), .5).passed, true);

      final saved = await File(output).readAsBytes();
      final unsupported = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/mmx.dart',
        'solid',
        input,
        output,
        '--mode',
        'fast',
        '--min-thickness',
        '.5',
      ]);
      expect(unsupported.exitCode, 1);
      expect(await File(output).readAsBytes(), saved);
      final invalid = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/mmx.dart',
        'solid',
        input,
        output,
        '--attempts',
        '0',
      ]);
      expect(invalid.exitCode, 2);
      expect(await File(output).readAsBytes(), saved);
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
