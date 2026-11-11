import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mmx_core/mmx_core.dart';

/// Observational benchmark: compile with `dart compile exe` before measuring.
/// History payload is distinct from process RSS and does not include VM overhead.
void main() {
  if (!const bool.fromEnvironment('dart.vm.product')) {
    throw StateError('Compile tool/history_memory.dart to an AOT executable');
  }
  const side = 225, samples = 30;
  final positions = Float32List(side * side * 3);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final i = (y * side + x) * 3;
      positions[i] = x.toDouble();
      positions[i + 1] = y.toDouble();
    }
  }
  final indices = Uint32List((side - 1) * (side - 1) * 6);
  var next = 0;
  for (var y = 0; y < side - 1; y++) {
    for (var x = 0; x < side - 1; x++) {
      final a = y * side + x, b = a + side;
      indices.setAll(next, [a, a + 1, b + 1, a, b + 1, b]);
      next += 6;
    }
  }
  final mesh = TriMesh(positions, indices);
  final inputDigest = sha256.convert([
    ...positions.buffer.asUint8List(),
    ...indices.buffer.asUint8List(),
  ]).toString();
  final doc = Document()..add(mesh);
  final liveBytes = doc.memoryBytes;
  final metadataMicros = <int>[], sparseMicros = <int>[];
  final timer = Stopwatch();
  for (var i = 0; i < samples; i++) {
    timer
      ..reset()
      ..start();
    doc.snapshot('Transform $i');
    timer.stop();
    metadataMicros.add(timer.elapsedMicroseconds);
    doc.objects.single.transform[12] = i + 1;
  }
  final metadataHistoryBytes = doc.historyBytes;
  for (var i = 0; i < samples; i++) {
    timer
      ..reset()
      ..start();
    doc.snapshot('Sculpt $i');
    timer.stop();
    sparseMicros.add(timer.elapsedMicroseconds);
    doc.objects.single.mesh.positions[1000 * 3 + 2] = (i + 1) / 10;
  }
  final finalHistoryBytes = doc.historyBytes;
  var restored = 0;
  while (doc.undo()) {
    restored++;
  }
  if (restored != samples * 2 ||
      doc.objects.single.transform[12] != 0 ||
      doc.objects.single.mesh.positions[1000 * 3 + 2] != 0) {
    throw StateError('History restoration failed');
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'runtime': Platform.version,
    'os': Platform.operatingSystem,
    'sourceSha256': sha256
        .convert(File('lib/src/scene/document.dart').readAsBytesSync())
        .toString(),
    'inputSha256': inputDigest,
    'vertices': mesh.vertexCount,
    'faces': mesh.faceCount,
    'livePayloadBytes': liveBytes,
    'metadataHistoryBytes': metadataHistoryBytes,
    'finalHistoryBytes': finalHistoryBytes,
    'fullSnapshotPayloadEstimate': liveBytes * samples * 2,
    'metadataSamplesMicroseconds': metadataMicros,
    'sparseSamplesMicroseconds': sparseMicros,
    'undoEntriesRestored': restored,
    'processPeakRssBytes': ProcessInfo.maxRss,
    'limits': 'Payload counts exclude VM overhead; process peak RSS includes '
        'input preparation and is not isolated history allocation. Observational '
        'latencies on this host are not release budgets.',
  }));
}
