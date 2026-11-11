import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:mmx_core/mmx_core.dart';

void main() {
  late Directory directory;
  late String recipe, inputPath;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('mmx-scan-cli-');
    inputPath = '${directory.path}/cube.obj';
    final mesh = Modify.fitPrimitive(
        TriMesh(Float32List.fromList([-1, -1, -1, 1, 1, 1]), Uint32List(0)),
        PrimitiveKind.box);
    File(inputPath).writeAsBytesSync(MeshIO.writeBytes(inputPath, mesh));
    recipe = '${directory.path}/recipe.json';
    File(recipe).writeAsStringSync(jsonEncode(ScanRecipe([
      ScanStep('denoise', {'displacementMm': .02, 'iterations': 2}),
      ScanStep('repair', {'weldMm': .00001}),
    ]).toJson()));
  });
  tearDown(() => directory.deleteSync(recursive: true));
  Future<ProcessResult> run(List<String> args) => Process.run(
      Platform.resolvedExecutable, ['run', 'bin/mmx.dart', ...args]);
  test(
      'scan reports actual units, process assumptions and geometry fingerprint',
      () async {
    final r =
        await run(['scan', inputPath, '--units', 'cm', '--process', 'resin']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final data = jsonDecode(r.stdout as String) as Map;
    expect(data['inputUnits'], 'cm');
    expect(data['consumedMeshSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
        (data['findings'] as List).any(
            (f) => f['code'] == 'resinDrainage' && f['severity'] == 'unknown'),
        isTrue);
    final original = MeshIO.readFile(inputPath).bounds();
    expect(data['dimensionsMm'][0], closeTo(original.extentX * 10, .0001));
  });
  test('cleanup is reproducible, retains the input and refuses overwrites',
      () async {
    final input = File(inputPath);
    final before = input.readAsBytesSync();
    final output = '${directory.path}/clean.stl',
        report = '${directory.path}/report.json';
    final args = [
      'cleanup',
      input.path,
      output,
      '--recipe',
      recipe,
      '--report',
      report
    ];
    final first = await run(args);
    expect(first.exitCode, 0, reason: '${first.stderr}');
    final data = jsonDecode(File(report).readAsStringSync());
    expect(data['steps'], hasLength(2));
    expect(data['outputFileSha256'], hasLength(64));
    expect(data['preflight']['status'], isNot('certified'));
    final mesh = MeshIO.readFile(output);
    expect(MeshTopology(mesh).boundaryEdges(), isEmpty);
    expect(MeshTopology(mesh).nonManifoldEdges(), isEmpty);
    expect(mesh.signedVolume(), greaterThan(0));
    final outputBytes = File(output).readAsBytesSync();
    expect((await run(args)).exitCode, 1);
    expect(File(output).readAsBytesSync(), outputBytes);
    expect(input.readAsBytesSync(), before);
  });
  test('batch isolates a missing input and rejects colliding output names',
      () async {
    final out = '${directory.path}/batch';
    final r = await run([
      'batch',
      inputPath,
      '${directory.path}/missing.obj',
      '--recipe',
      recipe,
      '--outdir',
      out
    ]);
    expect(r.exitCode, 1, reason: '${r.stderr}');
    final data = jsonDecode(r.stdout as String);
    expect(data['results'][0]['ok'], isTrue);
    expect(data['results'][1]['ok'], isFalse);
    expect(File('$out/cube.stl.report.json').existsSync(), isTrue);
    final collision = await run([
      'batch',
      'cube.obj',
      'cube.ply',
      '--recipe',
      recipe,
      '--outdir',
      '${directory.path}/collision'
    ]);
    expect(collision.exitCode, 2);
    expect(Directory('${directory.path}/collision').existsSync(), isFalse);
  });
  test('invalid units, profiles and recipes fail before creating output',
      () async {
    for (final options in [
      ['--units', 'feet'],
      ['--width', '0']
    ]) {
      expect((await run(['scan', inputPath, ...options])).exitCode, 2);
    }
    File(recipe).writeAsStringSync('{"version":99,"units":"mm","steps":[]}');
    final output = '${directory.path}/invalid.stl';
    expect(
        (await run(['cleanup', inputPath, output, '--recipe', recipe]))
            .exitCode,
        2);
    expect(File(output).existsSync(), isFalse);
  });
  test(
      'legacy repair preserves intentional openings unless filling is explicit',
      () async {
    final mesh = MeshIO.readFile(inputPath);
    final open = mesh.extractFaces([
      for (var f = 0; f < mesh.faceCount; f++)
        if (f != 2 && f != 3) f
    ]);
    File(inputPath).writeAsBytesSync(MeshIO.writeBytes(inputPath, open));
    final preserved = '${directory.path}/preserved.stl',
        filled = '${directory.path}/filled.stl';
    final first = await run(['repair', inputPath, preserved]);
    expect(first.exitCode, 0, reason: '${first.stderr}');
    expect(
        MeshTopology(MeshIO.readFile(preserved)).boundaryLoops(), hasLength(1));
    final second = await run(['repair', inputPath, filled, '--fill-holes']);
    expect(second.exitCode, 0, reason: '${second.stderr}');
    final result = MeshIO.readFile(filled);
    expect(MeshTopology(result).boundaryEdges(), isEmpty);
    expect(MeshTopology(result).nonManifoldEdges(), isEmpty);
    expect(result.signedVolume(), closeTo(8, .0001));
  });
}
