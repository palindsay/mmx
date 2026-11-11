import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_core/src/io/mtl.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
Uint8List _png({bool transparent = false}) {
  final image = img.Image(width: 2, height: 2, numChannels: 4);
  image.setPixelRgba(0, 0, 255, 0, 0, transparent ? 0 : 255);
  image.setPixelRgba(1, 0, 0, 255, 0, transparent ? 0 : 255);
  image.setPixelRgba(0, 1, 0, 0, 255, transparent ? 0 : 255);
  image.setPixelRgba(1, 1, 255, 255, 255, transparent ? 0 : 255);
  return img.encodePng(image);
}

TriMesh _mesh({bool textured = true}) => TriMesh(
        Float32List.fromList([-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0]),
        Uint32List.fromList([0, 1, 2, 0, 2, 3]),
        cornerUvs: textured
            ? Float32List.fromList([0, 0, 1, 0, 1, 1, .25, .25, .75, .75, 0, 1])
            : null,
        faceMaterials: Uint16List.fromList([0, 0]),
        materials: [
          MeshMaterial(
              name: 'paint',
              baseColor: textured ? [1, 1, 1, 1] : [.2, .4, .6, 1],
              texture: textured
                  ? TextureIO.decode(_png(), name: 'swatch.png')
                  : null)
        ]);

void main() {
  group('immutable surface attributes', () {
    test('texture decode and material validation are bounded and immutable',
        () {
      final png = _png(), texture = TextureIO.decode(png);
      expect(texture.width, 2);
      expect(texture.height, 2);
      expect(texture.rgba.take(4), [255, 0, 0, 255]);
      png[0] = 0;
      expect(texture.bytes[0], 137);
      expect(() => texture.rgba[0] = 0, throwsUnsupportedError);
      expect(() => texture.bytes[0] = 0, throwsUnsupportedError);
      final color = [.1, .2, .3, 1.0];
      final material = MeshMaterial(baseColor: color);
      color[0] = 1;
      expect(material.baseColor[0], .1);
      expect(() => material.baseColor[0] = 0, throwsUnsupportedError);
      expect(() => TextureIO.decode(_png(), maxDecodedBytes: 1),
          throwsFormatException);
      expect(
          () => MeshMaterial(baseColor: [1, 1, 2, 1]), throwsFormatException);
      expect(
          () => MeshTexture(
              name: 'bad',
              mimeType: 'image/png',
              width: 100000,
              height: 100000,
              bytes: Uint8List(1),
              rgba: Uint8List(0)),
          throwsFormatException);
      final jpg = img.encodeJpg(
          img.Image(width: 3, height: 2)..clear(img.ColorRgb8(40, 90, 180)));
      final jpeg = TextureIO.decode(jpg);
      expect(jpeg.mimeType, 'image/jpeg');
      expect(jpeg.rgba.length, 24);
    });
    test('clone, face extraction, winding and compaction preserve UV seams',
        () {
      final mesh = _mesh(), clone = mesh.clone();
      expect(identical(clone.materials.first, mesh.materials.first), isTrue);
      clone.cornerUvs![0] = 99;
      expect(mesh.cornerUvs![0], 0);
      final part = mesh.extractFaces([1]);
      expect(part.cornerUvs, mesh.cornerUvs!.sublist(6));
      expect(part.validate(), isEmpty);
      expect(part.faceMaterials, [0]);
      final reflected = mesh.clone()..transform(scale4(-1));
      expect(reflected.cornerUvs!.take(6), [0, 0, 1, 1, 1, 0]);
      expect(reflected.validate(), isEmpty);
      final flipped = Modify.flipNormals(mesh);
      expect(flipped.cornerUvs, reflected.cornerUvs);
      expect(Modify.smooth(mesh).cornerUvs, mesh.cornerUvs);
      final duplicate = Modify.combine([mesh, mesh]);
      expect(duplicate.cornerUvs, [...mesh.cornerUvs!, ...mesh.cornerUvs!]);
      expect(duplicate.materials.length, 1);
      expect(duplicate.validate(), isEmpty);
      expect(
          Mirror.mirror(mesh, point: [0, 0, 0], normal: [1, 0, 0]).validate(),
          isEmpty);
      final bad = mesh.clone()..cornerUvs = Float32List(2);
      expect(bad.validate(), contains('invalid corner UVs'));
    });
    test('linear subdivision interpolates each side of a UV seam independently',
        () {
      final source = _mesh(),
          subdivided = IsotropicRemesher.linearSubdivide(_mesh());
      expect(subdivided.faceCount, 8);
      expect(subdivided.validate(), isEmpty);
      expect(subdivided.cornerUvs!.take(6), [0, 0, .5, 0, .5, .5]);
      expect(subdivided.cornerUvs!.sublist(24, 30),
          [.25, .25, .5, .5, .125, .625]);
      expect(subdivided.faceMaterials, List.filled(8, 0));
      expect(subdivided.surfaceArea(), closeTo(source.surfaceArea(), 1e-8));
      expect(MeshTopology(subdivided).nonManifoldEdges(), isEmpty);
    });
    test(
        'unwrap returns a mesh with durable UVs and leaves the source untouched',
        () {
      final mesh = _mesh(textured: false),
          result = Unwrap.planar(mesh, axis: 2);
      expect(mesh.cornerUvs, isNull);
      expect(result.mesh.cornerUvs!.length, 12);
      final back = ProjectIO.read(
              ProjectIO.write(ProjectData([SceneObject(1, 'uv', result.mesh)])))
          .objects
          .single
          .mesh;
      expect(back.cornerUvs, result.mesh.cornerUvs);
    });
    test('unsupported topology and lossy exports fail explicitly', () {
      final mesh = _mesh();
      expect(() => Decimator.reduce(mesh), throwsUnsupportedError);
      expect(() => IsotropicRemesher.remesh(mesh, targetEdgeLength: 1),
          throwsUnsupportedError);
      expect(() => PlaneCut.cut(mesh, point: [0, 0, 0], normal: [1, 0, 0]),
          throwsUnsupportedError);
      expect(() => HoleFiller.fill(mesh), throwsUnsupportedError);
      expect(
          () => Sculptor.apply(mesh,
              op: BrushOp.draw,
              center: [0, 0, 0],
              radius: 1,
              strength: .1,
              refine: true),
          throwsUnsupportedError);
      for (final ext in ['stl', 'ply', 'mix']) {
        expect(() => MeshIO.writeBytes('f.$ext', mesh), throwsFormatException);
      }
      expect(() => ObjIO.write(mesh), throwsFormatException);
      expect(
          () => ThreeMfIO.write(_mesh()
            ..materials = [
              MeshMaterial(
                  texture: mesh.materials.first.texture,
                  baseColor: [.5, 1, 1, 1])
            ]),
          throwsFormatException);
    });
  });
  group('format round trips', () {
    test('persistence rejects mismatched caller-supplied texture sources', () {
      final decoded = TextureIO.decode(_png());
      final mismatched = Uint8List.fromList(decoded.rgba)..[0] = 0;
      for (final texture in [
        MeshTexture(
            name: 'invalid bytes',
            mimeType: decoded.mimeType,
            width: decoded.width,
            height: decoded.height,
            bytes: Uint8List.fromList([1]),
            rgba: decoded.rgba),
        MeshTexture(
            name: 'different pixels',
            mimeType: decoded.mimeType,
            width: decoded.width,
            height: decoded.height,
            bytes: decoded.bytes,
            rgba: mismatched),
        MeshTexture(
            name: 'different metadata',
            mimeType: 'image/jpeg',
            width: decoded.width,
            height: decoded.height,
            bytes: decoded.bytes,
            rgba: decoded.rgba),
      ]) {
        final mesh = _mesh()..materials = [MeshMaterial(texture: texture)];
        expect(() => ObjIO.writeBundle(mesh), throwsFormatException);
        expect(() => ThreeMfIO.write(mesh), throwsFormatException);
        expect(
            () => ProjectIO.write(ProjectData([SceneObject(1, 'mesh', mesh)])),
            throwsFormatException);
      }
      final valid = MeshTexture(
          name: decoded.name,
          mimeType: decoded.mimeType,
          width: decoded.width,
          height: decoded.height,
          bytes: decoded.bytes,
          rgba: decoded.rgba);
      final mesh = _mesh()..materials = [MeshMaterial(texture: valid)];
      final restored = ProjectIO.read(
          ProjectIO.write(ProjectData([SceneObject(1, 'mesh', mesh)])));
      expect(restored.objects.single.mesh.materials.single.texture!.rgba,
          decoded.rgba);
    });
    test(
        'standalone export commits without assets and failed OBJ commits clean staging',
        () async {
      final dir = await Directory.systemTemp.createTemp('mmx-export-');
      try {
        final plain = _mesh(textured: false)
          ..materials = []
          ..faceMaterials = null;
        final path = '${dir.path}/plain.stl';
        expect(
            await MeshIO.commitExport(path, MeshIO.prepareExport(path, plain)),
            isNull);
        expect(MeshIO.readFile(path).surfaceArea(), plain.surfaceArea());
        await MeshIO.writeFile(path, plain, binaryStl: false);
        expect(MeshIO.readFile(path).faceCount, 2);
        final blocked = await Directory('${dir.path}/blocked.obj').create();
        final before = dir.listSync().map((e) => e.path).toSet();
        await expectLater(
            MeshIO.commitExport(
                blocked.path, MeshIO.prepareExport(blocked.path, _mesh())),
            throwsA(isA<FileSystemException>()));
        expect(dir.listSync().map((e) => e.path).toSet(), before);
      } finally {
        await dir.delete(recursive: true);
      }
    });
    test('OBJ resolves material and library names with internal whitespace',
        () {
      for (final name in ['two  spaces', 'tab\tseparated']) {
        final mesh = _mesh()
          ..materials = [
            MeshMaterial(name: name, texture: _mesh().materials.first.texture)
          ];
        final assets = ObjIO.writeBundle(mesh,
            materialLibraryReference: 'material  library.mtl');
        assets['material  library.mtl'] = assets.remove('mesh.mtl')!;
        final back = ObjIO.read(utf8.decode(assets['mesh.obj']!),
            readAsset: (path) => assets[path]!);
        expect(back.materials.single.name, name);
        expect(back.cornerUvs, mesh.cornerUvs);
      }
    });
    test('OBJ MTL PNG retains seams, negative UV indices and diffuse opacity',
        () {
      final mesh = _mesh(),
          bundle = ObjIO.writeBundle(_mesh(), filename: 'paint.obj');
      final source = utf8.decode(bundle['paint.obj']!);
      final back = ObjIO.read(source, readAsset: (path) => bundle[path]!);
      expect(back.cornerUvs, mesh.cornerUvs);
      expect(back.faceMaterials, mesh.faceMaterials);
      expect(back.materials.single.name, 'paint');
      expect(back.materials.single.texture!.bytes,
          mesh.materials.single.texture!.bytes);
      final negative =
          'v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nf 1/-3 2/-2 3/-1';
      expect(ObjIO.read(negative).cornerUvs, [0, 0, 1, 0, 0, 1]);
      final materials = MtlIO.read(
          'newmtl red\nKd 1 0 0\nTr .25\nKa 0 0 0\nKs 0 0 0\nNs 50\nNi 1',
          readAsset: (_) => throw StateError('unused'));
      expect(materials['red']!.baseColor, [1, 0, 0, .75]);
      expect(() => ObjIO.read(source), throwsFormatException);
    });
    test('OBJ nested asset paths, atomic export and path escapes', () async {
      final dir = await Directory.systemTemp.createTemp('mmx-texture-');
      try {
        final output = '${dir.path}/colored model.obj';
        final prepared = MeshIO.prepareExport(output, _mesh());
        expect(dir.listSync(), isEmpty,
            reason: 'Worker preparation must have no filesystem effects');
        final companions = await MeshIO.commitExport(output, prepared);
        expect(companions, isNotNull);
        expect(Directory(companions!).existsSync(), isTrue);
        expect(companions.split(Platform.pathSeparator).last,
            startsWith('mmx-assets-'));
        final back = MeshIO.readFile(output);
        expect(back.cornerUvs, _mesh().cornerUvs);
        expect(back.materials.single.texture!.width, 2);
        final original = File(output).readAsBytesSync();
        await expectLater(
            MeshIO.writeFile(output, _mesh()..cornerUvs = Float32List(1)),
            throwsFormatException);
        expect(File(output).readAsBytesSync(), original);
        File(output).writeAsStringSync('mtllib ../outside.mtl\n');
        expect(() => MeshIO.readFile(output), throwsFormatException);
        for (final path in [
          '/etc/passwd',
          'C:\\secret.mtl',
          'https://example.com/a',
          'a/../../b',
          'a\u0000b'
        ]) {
          expect(
              () => ObjIO.read('mtllib $path',
                  readAsset: (_) => throw StateError('must not read')),
              throwsFormatException);
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
    test(
        'native schema 3 persists immutable image bytes, RGBA, UVs and opaque imports',
        () {
      final source = _mesh();
      final project = ProjectData([
        SceneObject(1, 'paint', source),
        SceneObject(2, 'copy', source.clone())
      ], sourceAttachments: [
        ProjectSourceAttachment(
            name: 'source.mix', bytes: Uint8List.fromList([1, 2, 3, 4]))
      ]);
      final encoded = ProjectIO.write(project),
          entries = ZipArchive.read(ProjectIO.write(project));
      expect(entries.where((e) => e.name.startsWith('textures/')).length, 1);
      expect(jsonDecode(utf8.decode(entries.first.data))['version'], 3);
      final back = ProjectIO.read(encoded);
      expect(back.objects.first.mesh.cornerUvs, source.cornerUvs);
      final texture = back.objects.first.mesh.materials.single.texture!;
      expect(texture.bytes, source.materials.single.texture!.bytes);
      expect(texture.rgba, source.materials.single.texture!.rgba);
      expect(
          identical(texture, back.objects.last.mesh.materials.single.texture),
          isTrue);
      expect(back.sourceAttachments.single.bytes, [1, 2, 3, 4]);
    });
    test(
        'vertex RGB 3MF groups preserve shared vertices and reject color seams',
        () {
      final mesh = _mesh(textured: false)
        ..materials = []
        ..faceMaterials = null
        ..vertexColors =
            Float32List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1]);
      final back = ThreeMfIO.read(ThreeMfIO.write(mesh));
      expect(back.vertexColors, mesh.vertexColors);
      expect(back.indices, mesh.indices);
      final archive = ZipArchive.read(ThreeMfIO.write(mesh));
      final bad = ZipArchive.write([
        for (final e in archive)
          e.name.endsWith('.model')
              ? ZipEntry(
                  e.name,
                  _bytes(utf8.decode(e.data).replaceFirst(
                      'v1="0" v2="2" v3="3" pid="2" p1="0"',
                      'v1="0" v2="2" v3="3" pid="2" p1="1"')))
              : e
      ]);
      expect(() => ThreeMfIO.read(bad), throwsFormatException);
    });
    test(
        'seeded metamorphic OBJ/native/3MF round trips retain UVs after transforms',
        () {
      final random = math.Random(20261111);
      for (var i = 0; i < 12; i++) {
        final mesh = _mesh();
        for (var k = 0; k < mesh.cornerUvs!.length; k++) {
          mesh.cornerUvs![k] = random.nextDouble() * 4 - 2;
        }
        mesh.transform(multiply4(
            translation4(i.toDouble(), 0, 0), scale4(i.isEven ? -2 : 3)));
        final bundle = ObjIO.writeBundle(mesh);
        for (final back in [
          ObjIO.read(utf8.decode(bundle['mesh.obj']!),
              readAsset: (p) => bundle[p]!),
          ThreeMfIO.read(ThreeMfIO.write(mesh)),
          ProjectIO.read(ProjectIO.write(
                  ProjectData([SceneObject(1, 'metamorphic', mesh)])))
              .objects
              .single
              .mesh
        ]) {
          expect(back.validate(), isEmpty);
          expect(back.cornerUvs, mesh.cornerUvs);
          expect(back.surfaceArea(), closeTo(mesh.surfaceArea(), 1e-6));
          expect(MeshTopology(back).nonManifoldEdges(), isEmpty);
        }
      }
    });
    test(
        'texture history shares immutable payloads while UV edits remain independent',
        () {
      final texture = TextureIO.decode(img.encodePng(
          img.Image(width: 256, height: 256, numChannels: 4)
            ..clear(img.ColorRgba8(30, 60, 90, 255))));
      final mesh = _mesh()..materials = [MeshMaterial(texture: texture)];
      final doc = Document()..add(mesh);
      for (var i = 0; i < 25; i++) {
        doc.snapshot('UV $i');
        mesh.cornerUvs![0] = i / 100;
      }
      expect(doc.historyBytes, lessThan(texture.byteSize + 50000));
      for (var i = 24; i >= 1; i--) {
        expect(doc.undo(), isTrue);
        expect(doc.objects.single.mesh.cornerUvs![0],
            closeTo((i - 1) / 100, 1e-6));
        expect(doc.objects.single.mesh.materials.single.texture, same(texture));
      }
    });
    test('3MF rejects UV loss on untextured faces in a mixed material mesh',
        () {
      final mesh = _mesh();
      mesh.materials = [mesh.materials.single, MeshMaterial(name: 'plain')];
      mesh.faceMaterials![1] = 1;
      expect(() => ThreeMfIO.write(mesh), throwsFormatException);
      // Imported mixed 3MF meshes use zero placeholders for plain faces. They
      // remain round-trippable while actual untextured mappings reject above.
      mesh.cornerUvs!.fillRange(6, 12, 0);
      final restored = ThreeMfIO.read(ThreeMfIO.write(mesh));
      expect(restored.cornerUvs, mesh.cornerUvs);
      expect(restored.faceMaterials, mesh.faceMaterials);
      mesh.faceMaterials!.fillRange(0, 2, 1);
      mesh.cornerUvs!.fillRange(0, 12, 0);
      // An unused textured material must not hide the lack of mapped faces.
      expect(() => ThreeMfIO.write(mesh), throwsFormatException);
    });
    test('3MF base material and texture packages preserve supported appearance',
        () {
      for (final source in [_mesh(), _mesh(textured: false)]) {
        final back = ThreeMfIO.read(ThreeMfIO.write(source));
        expect(back.validate(), isEmpty);
        expect(back.positions, source.positions);
        expect(back.cornerUvs, source.cornerUvs);
        expect(back.faceMaterials, source.faceMaterials);
        expect(
            back.materials.single.baseColor, source.materials.single.baseColor);
        expect(back.materials.single.texture?.bytes,
            source.materials.single.texture?.bytes);
        expect(back.surfaceArea(), source.surfaceArea());
      }
      final entries = ZipArchive.read(ThreeMfIO.write(_mesh()));
      for (final replace in <String Function(String)>[
        (s) => s.replaceAll('tilestyleu="wrap"', 'tilestyleu="mirror"'),
        (s) => s.replaceAll('p1="0"', 'p1="999"'),
        (s) =>
            s.replaceAll('contenttype="image/png"', 'contenttype="image/jpeg"'),
        (s) => s.replaceAll(
            'requiredextensions="m"', 'requiredextensions="other"'),
        (s) => s.replaceAll(
            '<resources>', '<resources><m:compositematerials id="99"/>')
      ]) {
        final bad = ZipArchive.write([
          for (final e in entries)
            e.name.endsWith('.model')
                ? ZipEntry(e.name, _bytes(replace(utf8.decode(e.data))))
                : e
        ]);
        expect(() => ThreeMfIO.read(bad), throwsFormatException);
      }
    });
  });
  group('CPU texture rendering', () {
    test('bilinear sampler uses v-up, repeat, clamp and preserved alpha', () {
      final texture = TextureIO.decode(_png());
      expect(Rasterizer.sampleTexture(texture, .25, .75), (1.0, 0.0, 0.0, 1.0));
      expect(Rasterizer.sampleTexture(texture, .25, .25), (0.0, 0.0, 1.0, 1.0));
      expect(Rasterizer.sampleTexture(texture, 1.25, .75),
          Rasterizer.sampleTexture(texture, .25, .75));
      expect(Rasterizer.sampleTexture(texture, -20, 20, clamp: true),
          (1.0, 0.0, 0.0, 1.0));
      expect(Rasterizer.sampleTexture(texture, .5, .5), (.5, .5, .5, 1.0));
    });
    test(
        'surface textures alter pixels and alpha cutout reveals the background',
        () {
      final mesh = _mesh(),
          camera = Camera(yaw: 0, pitch: 0, distance: 4, target: [0, 0, 0]);
      Uint8List render(TriMesh mesh) => Rasterizer.render(
              [
                RenderObject(mesh, transform: identity4(), color: [1, 1, 1])
              ],
              camera,
              const RenderOptions(
                  width: 64,
                  height: 64,
                  showGrid: false,
                  showBed: false,
                  ambient: 1,
                  background: [0, 0, 0]));
      final pixels = render(mesh), colors = <String>{};
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] + pixels[i + 1] + pixels[i + 2] > 0) {
          colors.add('${pixels[i]},${pixels[i + 1]},${pixels[i + 2]}');
        }
      }
      expect(colors.length, greaterThan(100));
      final transparent = mesh.clone()
        ..materials = [
          MeshMaterial(texture: TextureIO.decode(_png(transparent: true)))
        ];
      final cutout = render(transparent);
      for (var i = 0; i < cutout.length; i += 4) {
        expect(cutout.sublist(i, i + 4), [0, 0, 0, 255]);
      }
    });
  });
  test(
      'bounded seeded format mutations reach OBJ MTL PNG JPEG 3MF and project parsers',
      () {
    final random = math.Random(20261110),
        mesh = _mesh(),
        bundle = ObjIO.writeBundle(_mesh());
    final png = _png(), jpeg = img.encodeJpg(img.Image(width: 4, height: 4));
    for (var i = 0; i < 40; i++) {
      Uint8List mutate(Uint8List bytes) {
        final out = Uint8List.fromList(bytes);
        for (var j = 0; j < 1 + i % 3; j++) {
          out[random.nextInt(out.length)] = random.nextInt(256);
        }
        return out;
      }

      for (final action in <void Function()>[
        () => ObjIO.read(
                utf8.decode(mutate(bundle['mesh.obj']!), allowMalformed: true),
                readAsset: (p) =>
                    bundle[p] ?? (throw const FormatException('Missing asset')))
            .validate(),
        () => MtlIO.read(
            utf8.decode(mutate(bundle['mesh.mtl']!), allowMalformed: true),
            readAsset: (p) =>
                bundle[p] ?? (throw const FormatException('Missing asset'))),
        () => TextureIO.decode(mutate(png), maxDecodedBytes: 1048576),
        () => TextureIO.decode(mutate(jpeg), maxDecodedBytes: 1048576),
        () {
          final archive = ZipArchive.read(ThreeMfIO.write(mesh));
          final changed = [
            for (final e in archive)
              e.name.endsWith('.model') ? ZipEntry(e.name, mutate(e.data)) : e
          ];
          expect(ThreeMfIO.read(ZipArchive.write(changed)).validate(), isEmpty);
        },
        () {
          final archive = ZipArchive.read(
              ProjectIO.write(ProjectData([SceneObject(1, 'fuzz', mesh)])));
          archive[0] = ZipEntry(archive[0].name, mutate(archive[0].data));
          final decoded = ProjectIO.read(ZipArchive.write(archive));
          expect(decoded.objects.single.mesh.validate(), isEmpty);
        }
      ]) {
        try {
          action();
        } on FormatException {/* Bounded rejection. */}
      }
    }
  });
}
