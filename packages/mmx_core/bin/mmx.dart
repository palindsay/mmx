import 'dart:io';
import 'scan_commands.dart';
import 'dart:convert';
import 'package:args/args.dart';
import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';

const String _usage = '''
mmx — cross-platform mesh kernel CLI (Meshmixer-class operators)

  mmx scan <input> [--units mm|cm|m|inch] [--report report.json]
  mmx cleanup <input> <output> --recipe recipe.json
  mmx batch <inputs...> --recipe recipe.json --outdir directory
  mmx info <file> [--json]
  mmx repair <in> <out> [--weld 1e-5] [--fill-holes]
  mmx remesh <in> <out> --edge <len> [--iters 6] [--adaptive 0-1]
  mmx reduce <in> <out> --percent <0-1> | --faces <n> [--uniform] [--max-dev <d>]
  mmx solid <in> <out> [--mode fast|accurate|blocky] [--res 128] [--offset 0] [--smooth 0] [--min-thickness 0] [--max-growth <d>] [--attempts 6]
  mmx boolean <a> <b> <out> --op union|intersection|difference [--precise] [--edge <len>]
  mmx hollow <in> <out> --thickness <t> [--holes 3] [--hole-radius <r>] [--min-thickness 0] [--max-growth <d>] [--attempts 6]
  mmx offset <in> <out> --distance <d>
  mmx supports <in> <out> [--angle 45] [--density 0.5] [--bed 0]
  mmx pack <out> <in...> [--bed 200] [--quality 1]
  mmx slice <in> [--layer 0.2]
  mmx analyze <in> [--thickness 1.0] [--overhang 45] [--json]
  mmx mirror <in> <out> [--plane <x>] [--keep] [--weld <tol>]
  mmx flip <in> <out>
  mmx smooth <in> <out> [--iters 8]
  mmx drop <in> <out> [--bed 0]
  mmx center <in> <out> [--bed 0]
  mmx duplicate <in> <out> [--dx 0] [--dy 0] [--dz 0]
  mmx combine <out> <in...>
  mmx pattern <in> <out> [--nx 3] [--nz 2] [--gap 2]
  mmx primitive <in> <out> [--kind box|cylinder|sphere]
  mmx measure <in> [--json]
  mmx clearance <a> <b>
  mmx convert <in> <out> [.mix supported]
  mmx render <in> <out.png> [--width 960] [--height 640] [--yaw 0.6] [--pitch 0.35] [--wire]
''';

class UsageError implements Exception {
  final String message;
  UsageError(this.message);
  @override
  String toString() => message;
}

void reportWallCertificate(SolidResult result) {
  final certificate = result.wallCertificate;
  if (certificate == null) return;
  stdout.writeln(jsonEncode({
    'wallClearance': {
      'metric': WallThicknessCertificate.metric,
      'status': certificate.status.name,
      'verifiedLowerBound': certificate.verifiedLowerBound,
      'numericalMargin': certificate.numericalMargin,
      'candidatePairs': certificate.candidatePairs,
      'appliedOffset': result.appliedOffset,
      'appliedShellThickness': result.appliedShellThickness,
      'attempts': result.thicknessAttempts,
      'reconstruction': result.reconstruction,
      'reconstructionDiagnostic': result.reconstructionDiagnostic,
    }
  }));
}

Future<void> main(List<String> args) async {
  try {
    await run(args);
  } on UsageError catch (e) {
    stderr.writeln('$e\nUse mmx --help for usage.');
    exitCode = 2;
  } on Object catch (e) {
    stderr.writeln('mmx: $e');
    exitCode = 1;
  }
}

Future<void> run(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.writeln(_usage);
    return;
  }
  if ({'scan', 'cleanup', 'batch'}.contains(args.first)) {
    await runScanCommand(args);
    return;
  }
  const specs = <String, (int, String)>{
    'info': (1, 'json'),
    'repair': (2, 'weld fill-holes'),
    'remesh': (2, 'edge iters adaptive debug-topology'),
    'reduce': (2, 'percent faces uniform max-dev'),
    'solid': (2, 'mode res offset smooth min-thickness max-growth attempts'),
    'boolean': (3, 'op precise edge res'),
    'hollow': (
      2,
      'thickness holes hole-radius res min-thickness max-growth attempts'
    ),
    'offset': (2, 'distance res'),
    'supports': (2, 'angle density post base bed'),
    'pack': (2, 'bed quality'),
    'slice': (1, 'layer'),
    'analyze': (1, 'thickness overhang json'),
    'mirror': (2, 'plane keep weld'),
    'separate': (2, ''),
    'merge': (2, ''),
    'combine': (2, ''),
    'flip': (2, ''),
    'smooth': (2, 'iters'),
    'drop': (2, 'bed'),
    'center': (2, 'bed'),
    'duplicate': (2, 'dx dy dz'),
    'pattern': (2, 'nx nz gap'),
    'primitive': (2, 'kind'),
    'measure': (1, 'json'),
    'clearance': (2, ''),
    'convert': (2, ''),
    'render': (2, 'width height yaw pitch wire bed'),
  };
  final cmd = args.first;
  final spec = specs[cmd];
  if (spec == null) throw UsageError('Unknown command: $cmd');
  final parser = ArgParser()..addFlag('help', abbr: 'h', negatable: false);
  const switches = {
    'fill-holes',
    'precise',
    'keep',
    'uniform',
    'wire',
    'debug-topology',
    'json'
  };
  for (final key in spec.$2.split(' ').where((s) => s.isNotEmpty)) {
    if (switches.contains(key)) {
      parser.addFlag(key, negatable: false);
    } else {
      parser.addOption(key);
    }
  }
  late ArgResults parsed;
  try {
    parsed = parser.parse(args.sublist(1));
  } on FormatException catch (e) {
    throw UsageError(e.message);
  }
  if (parsed['help'] == true) {
    stdout.writeln(_usage);
    stdout.writeln(parser.usage);
    return;
  }
  final positional = parsed.rest;
  final variable = {'pack', 'merge', 'combine'}.contains(cmd);
  if (positional.length < spec.$1 ||
      (!variable && positional.length != spec.$1)) {
    throw UsageError(
        '$cmd requires ${variable ? "at least " : ""}${spec.$1} path arguments');
  }
  final flags = <String, String>{
    for (final key in parser.options.keys)
      if (parsed.wasParsed(key)) key: parsed[key].toString()
  };
  const enums = {
    'mode': ['fast', 'accurate', 'blocky'],
    'op': ['union', 'intersection', 'difference'],
    'kind': ['box', 'cylinder', 'sphere']
  };
  const integers = {
    'attempts',
    'faces',
    'iters',
    'res',
    'smooth',
    'holes',
    'quality',
    'nx',
    'nz',
    'width',
    'height'
  };
  const signed = {
    'offset',
    'distance',
    'bed',
    'plane',
    'dx',
    'dy',
    'dz',
    'yaw',
    'pitch'
  };
  for (final e in flags.entries) {
    if (switches.contains(e.key)) continue;
    if (enums.containsKey(e.key)) {
      if (!enums[e.key]!.contains(e.value)) {
        throw UsageError('Invalid --${e.key}: ${e.value}');
      }
      continue;
    }
    final n = double.tryParse(e.value);
    if (n == null ||
        !n.isFinite ||
        (integers.contains(e.key) && n != n.truncateToDouble()) ||
        (!signed.contains(e.key) && n < 0)) {
      throw UsageError('Invalid --${e.key}: ${e.value}');
    }
    if ({
          'edge',
          'thickness',
          'hole-radius',
          'layer',
          'post',
          'base',
          'width',
          'height',
          'nx',
          'nz',
          'faces',
          'quality'
        }.contains(e.key) &&
        n <= 0) {
      throw UsageError('--${e.key} must be positive');
    }
    if ({'percent', 'density', 'adaptive'}.contains(e.key) && n > 1) {
      throw UsageError('--${e.key} must be in [0,1]');
    }
    if ({'angle', 'overhang'}.contains(e.key) && n > 180) {
      throw UsageError('--${e.key} must be in [0,180]');
    }
    if (e.key == 'res' && (n < 8 || n > 256)) {
      throw UsageError('--res must be in [8,256]');
    }
    if (e.key == 'attempts' && (n < 1 || n > 12)) {
      throw UsageError('--attempts must be in [1,12]');
    }
    if ({'width', 'height'}.contains(e.key) && n > 4096) {
      throw UsageError('--${e.key} exceeds 4096');
    }
    if ({'iters', 'smooth', 'holes', 'nx', 'nz', 'quality'}.contains(e.key) &&
        n > 1000) {
      throw UsageError('--${e.key} exceeds 1000');
    }
  }
  if (flags.containsKey('percent') && flags.containsKey('faces')) {
    throw UsageError('Choose --percent or --faces');
  }

  TriMesh load(String path) {
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('missing file: $path');
      throw FileSystemException('Input file does not exist', path);
    }
    return MeshIO.readFile(path);
  }

  Future<void> save(String path, TriMesh mesh) async {
    final companions =
        await MeshIO.commitExport(path, MeshIO.prepareExport(path, mesh));
    stdout.writeln(
        'wrote $path (${mesh.vertexCount} verts, ${mesh.faceCount} faces)');
    if (companions != null) {
      stdout.writeln('Keep companion folder with OBJ: $companions');
    }
  }

  double flag(String name, double fallback) =>
      double.tryParse(flags[name] ?? '') ?? fallback;

  switch (cmd) {
    case 'info':
      {
        final mesh = load(positional[0]);
        if (flags.containsKey('json')) {
          stdout.writeln(jsonEncode({
            'vertices': mesh.vertexCount,
            'faces': mesh.faceCount,
            ...Modify.measure(mesh).toJson()
          }));
          return;
        }
        final topo = MeshTopology(mesh);
        final b = mesh.bounds();
        stdout.writeln('file: ${positional[0]}');
        stdout.writeln('verts: ${mesh.vertexCount}  faces: ${mesh.faceCount}');
        stdout.writeln(
            'bounds: ${b.minX.toStringAsFixed(2)},${b.minY.toStringAsFixed(2)},'
            '${b.minZ.toStringAsFixed(2)} .. ${b.maxX.toStringAsFixed(2)},'
            '${b.maxY.toStringAsFixed(2)},${b.maxZ.toStringAsFixed(2)}');
        stdout.writeln('area: ${mesh.surfaceArea().toStringAsFixed(3)}  '
            'volume: ${mesh.signedVolume().toStringAsFixed(3)}');
        final comps = topo.components().$2;
        stdout.writeln('components: $comps  '
            'boundaryLoops: ${topo.boundaryLoops().length}  '
            'nonManifoldEdges: ${topo.nonManifoldEdges().length}');
        stdout
            .writeln('avgValence: ${topo.averageValence().toStringAsFixed(2)}');
        final defects = MeshInspector.scan(mesh);
        final counts = <String, int>{};
        for (final d in defects) {
          counts[d.kind.name] = (counts[d.kind.name] ?? 0) + 1;
        }
        stdout.writeln('defects: $counts');
      }
    case 'repair':
      {
        var mesh = load(positional[0]);
        mesh = Weld.weldVertices(mesh, tolerance: flag('weld', 1e-5));
        mesh = Weld.weldCracks(mesh, tolerance: flag('weld', 1e-5));
        Weld.removeDuplicateFaces(mesh);
        mesh = MeshInspector.splitNonManifold(mesh);
        if (flags.containsKey('fill-holes')) {
          mesh = HoleFiller.fill(mesh,
              mode: HoleFillMode.smooth, requireAll: true);
        }
        final report = ScanWorkflow.inspect(mesh);
        await save(positional[1], mesh);
        stdout.writeln(jsonEncode(report.toJson()));
      }
    case 'remesh':
      {
        final mesh = load(positional[0]);
        final edge = flag('edge', mesh.bounds().diagonal / 100);
        final out = IsotropicRemesher.remeshDetailed(mesh,
            targetEdgeLength: edge,
            iterations: flag('iters', 6).toInt(),
            adaptiveDensity: flag('adaptive', 0),
            debugTopology: flags.containsKey('debug-topology'));
        if (out.usedUniformFallback) {
          stderr.writeln('remesh fallback: ${out.fallbackReason}');
        }
        await save(positional[1], out.mesh);
      }
    case 'reduce':
      {
        final mesh = load(positional[0]);
        final faces =
            flags.containsKey('faces') ? int.parse(flags['faces']!) : null;
        final pct = flags.containsKey('percent') ? flag('percent', 0.5) : null;
        final maxDev =
            flags.containsKey('max-dev') ? flag('max-dev', 0.0) : null;
        final out = Decimator.reduce(mesh,
            targetFaceCount: faces,
            percentage: pct,
            uniform: flags.containsKey('uniform'));
        if (maxDev != null) {
          if (maxDev <= 0) throw UsageError('--max-dev must be positive');
          final deviation = SurfaceDeviation.measure(mesh, out);
          if (deviation.maximum > maxDev) {
            throw StateError(
                'Sampled surface deviation ${deviation.maximum} exceeds $maxDev; use a less aggressive reduction');
          }
          stdout.writeln(jsonEncode({'deviation': deviation.toJson()}));
        }
        await save(positional[1], out);
      }
    case 'solid':
      {
        final mesh = load(positional[0]);
        final mode = switch (flags['mode'] ?? 'accurate') {
          'fast' => SolidMode.fast,
          'blocky' => SolidMode.blocky,
          _ => SolidMode.accurate,
        };
        final r = Solidifier.makeSolid(mesh,
            mode: mode,
            resolution: flag('res', 128).toInt(),
            offset: flag('offset', 0),
            smoothing: flag('smooth', 0).toInt(),
            minThickness: flag('min-thickness', 0),
            maxThicknessAttempts: flag('attempts', 6).toInt(),
            maxAdditionalOffset:
                flags.containsKey('max-growth') ? flag('max-growth', 0) : null);
        stdout.writeln(
            'grid ${r.gridResolution} cell ${r.cellSize.toStringAsFixed(4)} '
            '${r.elapsedMs}ms');
        await save(positional[1], r.mesh);
        reportWallCertificate(r);
      }
    case 'boolean':
      {
        final a = load(positional[0]);
        final b = load(positional[1]);
        final op = switch (flags['op'] ?? 'union') {
          'difference' => BooleanOp.difference,
          'intersection' => BooleanOp.intersection,
          _ => BooleanOp.union,
        };
        final r = flags.containsKey('precise')
            ? PreciseBoolean.computeDetailed(a, b, op,
                edgeLength:
                    flags['edge'] == null ? null : double.parse(flags['edge']!),
                resolution: flag('res', 160).toInt())
            : BooleanResult(Solidifier.boolean(a, b, op,
                    resolution: flag('res', 160).toInt())
                .mesh);
        if (r.usedFallback) {
          stderr.writeln('boolean fallback: ${r.fallbackReason}');
        }
        await save(positional[2], r.mesh);
      }
    case 'hollow':
      {
        final mesh = load(positional[0]);
        final r = Solidifier.hollow(mesh,
            thickness: flag('thickness', mesh.bounds().diagonal * 0.03),
            holes: flag('holes', 3).toInt(),
            holeRadius: flag('hole-radius', mesh.bounds().diagonal * 0.02),
            resolution: flag('res', 128).toInt(),
            minThickness: flag('min-thickness', 0),
            maxThicknessAttempts: flag('attempts', 6).toInt(),
            maxAdditionalThickness:
                flags.containsKey('max-growth') ? flag('max-growth', 0) : null);
        await save(positional[1], r.mesh);
        reportWallCertificate(r);
      }
    case 'offset':
      {
        final mesh = load(positional[0]);
        final r = Solidifier.offsetSolid(mesh, flag('distance', 1),
            resolution: flag('res', 128).toInt());
        await save(positional[1], r.mesh);
      }
    case 'supports':
      {
        final mesh = load(positional[0]);
        final settings = SupportSettings(
          overhangAngleDegrees: flag('angle', 45),
          density: flag('density', 0.5),
          postDiameter: flag('post', 2),
          baseDiameter: flag('base', 6),
        );
        final r = SupportGenerator.generate(mesh,
            settings: settings, bedY: flag('bed', 0));
        stdout.writeln('posts ${r.postCount} struts ${r.strutCount}');
        await save(positional[1], r.supports);
      }
    case 'pack':
      {
        final out = positional[0];
        final meshes = positional.sublist(1).map(load).toList();
        final r = Packer.pack(meshes,
            bedWidth: flag('bed', 200),
            bedDepth: flag('bed', 200),
            quality: flag('quality', 1).toInt());
        stdout.writeln('placed ${r.placed.length}/${meshes.length} '
            'utilisation ${(r.bedUtilization * 100).toStringAsFixed(1)}%');
        final merged = <TriMesh>[];
        for (final p in r.placed) {
          final m = meshes[p.index].clone();
          m.transform(Float64List.fromList(p.transform));
          merged.add(m);
        }
        var total = 0;
        for (final m in merged) {
          total += m.vertexCount;
        }
        final pos = Float32List(total * 3);
        var pi = 0;
        final idx = <int>[];
        var offset = 0;
        for (final m in merged) {
          pos.setRange(pi, pi + m.positions.length, m.positions);
          pi += m.positions.length;
          for (var i = 0; i < m.indices.length; i++) {
            idx.add(m.indices[i] + offset);
          }
          offset += m.vertexCount;
        }
        await save(out, TriMesh(pos, Uint32List.fromList(idx)));
      }
    case 'slice':
      {
        final mesh = load(positional[0]);
        final r = Slicer.slice(mesh, layerHeight: flag('layer', 0.2));
        stdout.writeln('layers ${r.layers.length}');
        for (final l in r.layers.take(3)) {
          stdout
              .writeln('  y=${l.y.toStringAsFixed(2)} loops=${l.loops.length} '
                  'closed=${l.loops.where((x) => x.closed).length}');
        }
      }
    case 'analyze':
      {
        final mesh = load(positional[0]);
        final t =
            ThicknessAnalysis.run(mesh, threshold: flag('thickness', 1.0));
        final o =
            OverhangAnalysis.run(mesh, angleDegrees: flag('overhang', 45));
        final s = StabilityAnalysis.run(mesh);
        final mp = MassProperties.compute(mesh);
        if (flags.containsKey('json')) {
          double? finite(double n) => n.isFinite ? n : null;
          stdout.writeln(jsonEncode({
            'volume': finite(mp.volume),
            'area': finite(mp.surfaceArea),
            'thickness': {
              'min': finite(t.minThickness),
              'mean': finite(t.meanThickness),
              'belowThreshold': t.belowThresholdCount
            },
            'overhang': {'faces': o.faceCount, 'area': finite(o.overhangArea)},
            'stability': {
              'centerInsideSupport': s.centerInsideSupport,
              'tipAngle': finite(s.minTipAngleDegrees)
            }
          }));
          return;
        }
        stdout.writeln('mass: volume=${mp.volume.toStringAsFixed(2)} '
            'area=${mp.surfaceArea.toStringAsFixed(2)} '
            'com=${mp.centerOfMass.map((v) => v.toStringAsFixed(2)).toList()}');
        stdout.writeln('thickness: min=${t.minThickness.toStringAsFixed(3)} '
            'mean=${t.meanThickness.toStringAsFixed(3)} '
            'belowThreshold=${t.belowThresholdCount}');
        stdout.writeln('overhang: faces=${o.faceCount} '
            'area=${o.overhangArea.toStringAsFixed(2)} '
            '(${(100 * o.overhangArea / (o.totalArea == 0 ? 1 : o.totalArea)).toStringAsFixed(1)}%)');
        stdout.writeln('stability: insideBase=${s.centerInsideSupport} '
            'tipAngle=${s.minTipAngleDegrees.toStringAsFixed(1)}deg '
            'contactArea=${s.bedContactArea.toStringAsFixed(2)}');
      }
    case 'mirror':
      {
        final mesh = load(positional[0]);
        final b = mesh.bounds();
        final out = Mirror.mirror(mesh,
            point: <double>[flag('plane', b.maxX), 0, 0],
            normal: <double>[1, 0, 0],
            keepOriginal: flags['keep'] == 'true',
            weldTolerance: flag('weld', b.diagonal * 1e-4));
        await save(positional[1], out);
      }
    case 'separate':
      {
        final mesh = load(positional[0]);
        final shells = ShellSeparator.separate(mesh);
        stdout.writeln('${shells.length} shells');
        final base = positional[1];
        final stem = base.contains('.')
            ? base.substring(0, base.lastIndexOf('.'))
            : base;
        final ext =
            base.contains('.') ? base.substring(base.lastIndexOf('.')) : '.obj';
        for (var i = 0; i < shells.length; i++) {
          await save('${stem}_${i + 1}$ext', shells[i]);
        }
      }
    case 'merge':
      {
        final meshes = positional.sublist(1).map(load).toList();
        var totalV = 0;
        var totalF = 0;
        for (final m in meshes) {
          totalV += m.vertexCount;
          totalF += m.faceCount;
        }
        final pos = Float32List(totalV * 3);
        final idx = Uint32List(totalF * 3);
        var pi = 0, ii = 0, off = 0;
        for (final m in meshes) {
          pos.setRange(pi, pi + m.positions.length, m.positions);
          pi += m.positions.length;
          for (var i = 0; i < m.indices.length; i++) {
            idx[ii++] = m.indices[i] + off;
          }
          off += m.vertexCount;
        }
        await save(positional[0], TriMesh(pos, idx));
      }
    case 'combine':
      {
        final meshes = positional.sublist(1).map(load).toList();
        await save(positional[0], Modify.combine(meshes));
      }
    case 'flip':
      await save(positional[1], Modify.flipNormals(load(positional[0])));
    case 'smooth':
      await save(
          positional[1],
          Modify.smooth(load(positional[0]),
              iterations: flag('iters', 8).toInt()));
    case 'drop':
      await save(positional[1],
          Modify.dropToBed(load(positional[0]), bedY: flag('bed', 0)));
    case 'center':
      await save(positional[1],
          Modify.centerOnBed(load(positional[0]), bedY: flag('bed', 0)));
    case 'duplicate':
      await save(
          positional[1],
          Modify.duplicate(load(positional[0]), offset: <double>[
            flag('dx', 0),
            flag('dy', 0),
            flag('dz', 0),
          ]));
    case 'pattern':
      await save(
          positional[1],
          Modify.makePattern(load(positional[0]),
              countX: flag('nx', 3).toInt(),
              countZ: flag('nz', 2).toInt(),
              gap: flag('gap', 2)));
    case 'primitive':
      {
        final kind = switch (flags['kind'] ?? 'box') {
          'sphere' => PrimitiveKind.sphere,
          'cylinder' => PrimitiveKind.cylinder,
          _ => PrimitiveKind.box,
        };
        await save(
            positional[1], Modify.fitPrimitive(load(positional[0]), kind));
      }
    case 'measure':
      {
        final r = Modify.measure(load(positional[0]));
        if (flags.containsKey('json')) {
          stdout.writeln(jsonEncode(r.toJson()));
          return;
        }
        stdout.writeln(
            'dimensions: ${r.dimensions.map((v) => v.toStringAsFixed(3)).join(' x ')}');
        stdout.writeln('area: ${r.surfaceArea.toStringAsFixed(3)}  '
            'volume: ${r.volume.toStringAsFixed(3)}');
        stdout.writeln(
            'centroid: ${r.centroid.map((v) => v.toStringAsFixed(3)).join(', ')}');
        stdout.writeln(
            'shells: ${r.shellCount}  boundaryEdges: ${r.boundaryEdgeCount}  '
            'watertight: ${r.watertight}');
      }
    case 'clearance':
      {
        final gap = Modify.clearance(load(positional[0]), load(positional[1]));
        stdout.writeln('clearance: ${gap.toStringAsFixed(3)}');
      }
    case 'convert':
      await save(positional[1], load(positional[0]));
    case 'render':
      {
        final mesh = load(positional[0]);
        final b = mesh.bounds();
        final cam = Camera(
          yaw: flag('yaw', 0.6),
          pitch: flag('pitch', 0.35),
          distance: 1,
        );
        cam.frame(b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ);
        final opts = RenderOptions(
          width: flag('width', 960).toInt(),
          height: flag('height', 640).toInt(),
          wireframe: flags['wire'] == 'true',
          bedSize: flag('bed', 200),
        );
        final sw = Stopwatch()..start();
        final rgba = Rasterizer.render(<RenderObject>[
          RenderObject(mesh,
              transform: identity4(), color: <double>[0.78, 0.72, 0.62]),
        ], cam, opts);
        sw.stop();
        final png = PngEncoder.encodeRGBA(rgba, opts.width, opts.height);
        await writeFileAtomically(positional[1], png);
        stdout.writeln(
            'rendered ${opts.width}x${opts.height} in ${sw.elapsedMilliseconds}ms '
            '-> ${positional[1]}');
      }
    default:
      stderr.writeln('unknown command: $cmd\n$_usage');
      exit(1);
  }
}
