import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:mmx_core/mmx_core.dart';

const scanUsage = '''Scan to print (input units must be specified correctly):
  mmx scan <input> [--units mm|cm|m|inch] [--report report.json]
  mmx cleanup <input> <output> --recipe recipe.json [--report report.json]
  mmx batch <inputs...> --recipe recipe.json --outdir <directory>

All commands accept --units, --process fdm|resin, --width 200, --depth 200,
--height 200, --wall 0.8, --border 2. Outputs use millimeters. Cleanup and batch
refuse to overwrite existing outputs. Recipes use {"version":1,"units":"mm",
"steps":[{"operation":"denoise","parameters":{"displacementMm":0.1}}]}.
Scan reports explicitly retain unchecked manufacturing assumptions.
''';

Future<void> runScanCommand(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('units', allowed: ['mm', 'cm', 'm', 'inch'], defaultsTo: 'mm')
    ..addOption('process', allowed: ['fdm', 'resin'], defaultsTo: 'fdm')
    ..addOption('width', defaultsTo: '200')
    ..addOption('depth', defaultsTo: '200')
    ..addOption('height', defaultsTo: '200')
    ..addOption('wall', defaultsTo: '0.8')
    ..addOption('border', defaultsTo: '2')
    ..addOption('report')
    ..addOption('recipe')
    ..addOption('outdir');
  try {
    final options = parser.parse(args.skip(1).toList());
    if (options['help'] == true) {
      stdout.writeln(scanUsage);
      return;
    }
    final command = args.first;
    final paths = options.rest;
    if ((command == 'scan' && paths.length != 1) ||
        (command == 'cleanup' && paths.length != 2) ||
        (command == 'batch' && paths.isEmpty)) {
      throw const FormatException('Wrong number of input/output paths');
    }
    double number(String key) {
      final v = double.tryParse(options[key] as String);
      if (v == null || !v.isFinite) throw FormatException('Invalid --$key');
      return v;
    }

    final profile = PrintProfile(
        process: options['process'] == 'resin'
            ? PrintProcess.resin
            : PrintProcess.fdm,
        width: number('width'),
        depth: number('depth'),
        height: number('height'),
        border: number('border'),
        minimumWall: number('wall'));
    profile.validate();
    final scale =
        {'mm': 1.0, 'cm': 10.0, 'm': 1000.0, 'inch': 25.4}[options['units']]!;
    TriMesh load(String path) {
      if (path.toLowerCase().endsWith('.3mf') && scale != 1) {
        throw const FormatException(
            '3MF already declares units; use --units mm');
      }
      final mesh = MeshIO.readFile(path);
      if (scale != 1) {
        mesh.transform(Float64List.fromList(
            [scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1]));
      }
      return mesh;
    }

    Future<void> report(String path, Object data) async {
      if (await File(path).exists()) {
        throw FileSystemException(
            'Refusing to overwrite an existing report', path);
      }
      await writeFileAtomically(
          path,
          Uint8List.fromList(utf8.encode(
              '${const JsonEncoder.withIndent('  ').convert(data)}\n')));
    }

    if (command == 'scan') {
      final mesh = load(paths[0]);
      final result = {
        ...ScanWorkflow.inspect(mesh, profile: profile).toJson(),
        'input': paths[0],
        'inputUnits': options['units'],
        'consumedMeshSha256': await meshFingerprint(mesh)
      };
      if (options['report'] != null) {
        await report(options['report'] as String, result);
      }
      stdout.writeln(jsonEncode(result));
      return;
    }
    final recipePath = options['recipe'] as String?;
    if (recipePath == null) throw const FormatException('--recipe is required');
    final recipeFile = File(recipePath);
    if (await recipeFile.length() > 1048576) {
      throw const FormatException('Recipe exceeds 1 MiB');
    }
    final decoded = jsonDecode(await recipeFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Recipe must be a JSON object');
    }
    final recipe = ScanRecipe.fromJson(decoded);
    Future<Map<String, Object?>> cleanup(
        String input, String output, String? reportPath) async {
      if (await File(output).exists()) {
        throw FileSystemException(
            'Refusing to overwrite an existing output', output);
      }
      if (reportPath != null &&
          (await File(reportPath).exists() ||
              File(reportPath).absolute.uri.normalizePath() ==
                  File(output).absolute.uri.normalizePath())) {
        throw FileSystemException(
            'Report must be a new path distinct from output', reportPath);
      }
      var mesh = load(input);
      final original = mesh.clone();
      final hash = await meshFingerprint(mesh);
      final steps = <Object>[];
      for (final step in recipe.steps) {
        final result = ScanRecipe.apply(mesh, step);
        steps.add({
          'step': step.toJson(),
          'inputFaces': mesh.faceCount,
          'outputFaces': result.mesh.faceCount,
          'deviation': result.deviation.toJson(),
          'note': result.note,
          'inferredGroup': result.inferredGroup
        });
        mesh = result.mesh;
      }
      final inspection = ScanWorkflow.inspect(mesh, profile: profile);
      final result = <String, Object?>{
        'input': input,
        'output': output,
        'inputUnits': options['units'],
        'inputMeshSha256': hash,
        'outputMeshSha256': await meshFingerprint(mesh),
        'recipe': recipe.toJson(),
        'steps': steps,
        'deviationFromOriginal':
            SurfaceDeviation.measure(original, mesh).toJson(),
        'preflight': inspection.toJson()
      };
      await MeshIO.commitExport(output, MeshIO.prepareExport(output, mesh));
      result['outputFileSha256'] =
          (await sha256.bind(File(output).openRead()).first).toString();
      if (reportPath != null) await report(reportPath, result);
      return result;
    }

    if (command == 'cleanup') {
      stdout.writeln(jsonEncode(
          await cleanup(paths[0], paths[1], options['report'] as String?)));
      return;
    }
    final outdir = options['outdir'] as String?;
    if (outdir == null) {
      throw const FormatException('--outdir is required for batch');
    }
    final names = paths.map((path) {
      final name = path.split(RegExp(r'[/\\]')).last;
      final dot = name.lastIndexOf('.');
      return '${dot > 0 ? name.substring(0, dot) : name}.stl';
    }).toList();
    if (names.map((n) => n.toLowerCase()).toSet().length != names.length) {
      throw const FormatException(
          'Batch inputs have colliding output filenames');
    }
    await Directory(outdir).create(recursive: true);
    final results = <Object>[];
    for (var i = 0; i < paths.length; i++) {
      final output = '$outdir/${names[i]}';
      try {
        results.add({
          'ok': true,
          ...await cleanup(paths[i], output, '$output.report.json')
        });
      } catch (e) {
        exitCode = 1;
        results.add({'ok': false, 'input': paths[i], 'error': '$e'});
      }
    }
    stdout.writeln(jsonEncode({'results': results}));
  } on FormatException catch (e) {
    stderr.writeln('$e\n$scanUsage');
    exitCode = 2;
  } on ArgumentError catch (e) {
    stderr.writeln('$e\n$scanUsage');
    exitCode = 2;
  }
}
