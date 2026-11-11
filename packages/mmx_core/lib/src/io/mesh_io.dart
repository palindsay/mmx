import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';
import '../tools/modify.dart';
import 'mix.dart';
import 'obj.dart';
import 'ply.dart';
import 'polygon_triangulation.dart';
import 'stl.dart';
import 'threemf.dart';
import 'asset_path.dart';
import 'atomic_file.dart';

/// Sendable encoded export. Preparing this value has no filesystem effects;
/// callers may cancel an encoding worker before committing it on the UI isolate.
class PreparedMeshExport {
  final Uint8List bytes;
  final Map<String, Uint8List> companions;
  final int referenceOffset, referenceLength;
  PreparedMeshExport._(this.bytes, Map<String, Uint8List> companions,
      {this.referenceOffset = 0, this.referenceLength = 0})
      : companions = Map.unmodifiable(companions);
}

/// Format sniffing and dispatch. Mirrors the import set observed in the
/// shipped Meshmixer binary: obj, ply, stl, off (plus amf/3mf/mix upstream).
class MeshIO {
  static const List<String> importExtensions = <String>[
    'obj',
    'ply',
    'stl',
    'off',
    '3mf',
    'mix'
  ];

  static const exportExtensions = <String>['stl', 'obj', 'ply', '3mf', 'mix'];
  static const maxFileBytes = 256 * 1024 * 1024;

  /// Resolve OBJ companions inside the chosen model's directory. Symlinks may
  /// not escape that directory; absolute paths and network URIs are rejected.
  static TriMesh readFile(String filename) {
    final file = File(filename);
    if (file.lengthSync() > maxFileBytes) {
      throw const FormatException('Mesh exceeds file limit');
    }
    if (!filename.toLowerCase().endsWith('.obj')) {
      return readBytes(filename, file.readAsBytesSync());
    }
    final root = file.absolute.parent.resolveSymbolicLinksSync();
    var total = 0, count = 0;
    final cache = <String, Uint8List>{};
    Uint8List asset(String name) => cache.putIfAbsent(safeAssetPath(name), () {
          if (++count > 4096) {
            throw const FormatException('Too many OBJ companions');
          }
          final relative =
              safeAssetPath(name).replaceAll('/', Platform.pathSeparator);
          final candidate = File('$root${Platform.pathSeparator}$relative');
          final resolved = candidate.resolveSymbolicLinksSync();
          final prefix = '$root${Platform.pathSeparator}';
          if (!(Platform.isWindows
              ? resolved.toLowerCase().startsWith(prefix.toLowerCase())
              : resolved.startsWith(prefix))) {
            throw const FormatException(
                'OBJ companion symlink escapes source directory');
          }
          final length = candidate.lengthSync();
          if (length > 16777216 || (total += length) > 67108864) {
            throw const FormatException('OBJ companion size limit exceeded');
          }
          return candidate.readAsBytesSync();
        });
    final mesh =
        ObjIO.read(utf8.decode(file.readAsBytesSync()), readAsset: asset);
    final errors = mesh.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join(', '));
    return mesh;
  }

  /// Pure encoding, suitable for a cancellable worker isolate.
  static PreparedMeshExport prepareExport(String filename, TriMesh mesh,
      {bool binaryStl = true}) {
    if (!filename.toLowerCase().endsWith('.obj') || mesh.materials.isEmpty) {
      return PreparedMeshExport._(
          writeBytes(filename, mesh, binaryStl: binaryStl), {});
    }
    const marker = 'mmx_companion_placeholder/mesh.mtl';
    final assets = ObjIO.writeBundle(mesh, materialLibraryReference: marker);
    final bytes = assets.remove('mesh.obj')!;
    final offset = utf8.encode('# exported by mmx_core\nmtllib ').length;
    return PreparedMeshExport._(bytes, assets,
        referenceOffset: offset, referenceLength: marker.length);
  }

  static Future<void> writeFile(String filename, TriMesh mesh,
      {bool binaryStl = true}) async {
    await commitExport(
        filename, prepareExport(filename, mesh, binaryStl: binaryStl));
  }

  /// Commit after cancellation/stale-result checks. This filesystem phase must
  /// not be killed mid-write. Existing exports survive companion write failures.
  static Future<String?> commitExport(
      String filename, PreparedMeshExport prepared) async {
    if (prepared.companions.isEmpty) {
      await writeFileAtomically(filename, prepared.bytes);
      return null;
    }
    final target = File(filename).absolute;
    final directory = await target.parent.createTemp('mmx-assets-');
    Directory? staging;
    var committed = false;
    try {
      for (final e in prepared.companions.entries) {
        await File('${directory.path}/${e.key}')
            .writeAsBytes(e.value, flush: true);
      }
      final relative =
          directory.uri.pathSegments.where((p) => p.isNotEmpty).last;
      staging = await target.parent.createTemp('.mmx-write-');
      final temporary = File('${staging.path}/payload');
      final output = await temporary.open(mode: FileMode.write);
      try {
        await output.writeFrom(prepared.bytes, 0, prepared.referenceOffset);
        await output.writeFrom(utf8.encode('$relative/mesh.mtl'));
        await output.writeFrom(prepared.bytes,
            prepared.referenceOffset + prepared.referenceLength);
        await output.flush();
      } finally {
        await output.close();
      }
      await temporary.rename(target.path);
      committed = true;
    } finally {
      if (staging != null) await staging.delete(recursive: true);
      if (!committed) await directory.delete(recursive: true);
    }
    return directory.path;
  }

  static TriMesh readBytes(String filename, Uint8List bytes) {
    if (bytes.length > maxFileBytes) {
      throw const FormatException('File exceeds 256 MiB limit');
    }
    try {
      final mesh = _readBytes(filename, bytes);
      final errors = mesh.validate();
      if (errors.isNotEmpty) throw FormatException(errors.join(', '));
      return mesh;
    } on RangeError {
      throw const FormatException('Truncated or invalid mesh data');
    }
  }

  static TriMesh _readBytes(String filename, Uint8List bytes) {
    final ext = filename.toLowerCase().split('.').last;
    switch (ext) {
      case 'stl':
        if (bytes.length >= 84 &&
            ByteData.sublistView(bytes).getUint32(80, Endian.little) * 50 +
                    84 ==
                bytes.length) {
          return StlIO.readBinary(bytes);
        }
        // ASCII STL starts with "solid" and contains "facet".
        final head = String.fromCharCodes(
            bytes.sublist(0, bytes.length < 512 ? bytes.length : 512));
        if (head.trimLeft().toLowerCase().startsWith('solid') &&
            (head.toLowerCase().contains('facet') ||
                head.toLowerCase().contains('endsolid'))) {
          return StlIO.readAscii(utf8.decode(bytes, allowMalformed: true));
        }
        return StlIO.readBinary(bytes);
      case 'ply':
        return PlyIO.read(bytes);
      case 'obj':
        return ObjIO.read(utf8.decode(bytes, allowMalformed: true));
      case 'off':
        return readOff(utf8.decode(bytes, allowMalformed: true));
      case '3mf':
        return ThreeMfIO.read(bytes);
      case 'mix':
        final objects = MixIO.read(bytes);
        if (objects.isEmpty) return TriMesh.empty();
        if (objects.length == 1) return objects.first.mesh;
        return Modify.combine(objects.map((o) => o.mesh).toList());
      default:
        throw FormatException('Unsupported import format: $ext');
    }
  }

  static TriMesh readOff(String text) {
    if (text.length > maxFileBytes) {
      throw const FormatException('OFF exceeds size limit');
    }
    final matches = RegExp(r'\S+')
        .allMatches(text.replaceAll(RegExp(r'#[^\r\n]*'), ''))
        .iterator;
    String token() {
      if (!matches.moveNext()) throw const FormatException('Truncated OFF');
      return matches.current.group(0)!;
    }

    if (token() != 'OFF') throw const FormatException('Invalid OFF header');
    final nv = int.parse(token()),
        nf = int.parse(token()),
        edges = int.parse(token());
    if (nv < 0 ||
        nv > 2000000 ||
        nf < 0 ||
        nf > 4000000 ||
        edges < 0 ||
        nv * 3 + nf * 4 > text.length) {
      throw const FormatException('Invalid OFF counts');
    }
    final positions = Float32List(nv * 3);
    for (var i = 0; i < positions.length; i++) {
      positions[i] = double.parse(token());
      if (!positions[i].isFinite) {
        throw const FormatException('Non-finite OFF coordinate');
      }
    }
    final indices = <int>[];
    for (var f = 0; f < nf; f++) {
      final n = int.parse(token());
      if (n < 3 || n > 4096) {
        throw const FormatException('Invalid OFF polygon size');
      }
      final polygon = List<int>.generate(n, (_) => int.parse(token()));
      final triangles = triangulatePolygon(positions, polygon);
      if (indices.length + triangles.length > 12000000) {
        throw const FormatException('OFF triangle limit exceeded');
      }
      indices.addAll(triangles);
    }
    return TriMesh(positions, Uint32List.fromList(indices));
  }

  static Uint8List writeBytes(String filename, TriMesh mesh,
      {bool binaryStl = true}) {
    final errors = mesh.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join(', '));
    final ext = filename.toLowerCase().split('.').last;
    if (!['obj', '3mf'].contains(ext) && mesh.hasSurfaceAttributes) {
      throw FormatException(
          '$ext export cannot preserve UV/materials. Use OBJ, 3MF or a native project, or explicitly remove surface attributes.');
    }
    switch (ext) {
      case 'stl':
        return binaryStl
            ? StlIO.writeBinary(mesh)
            : Uint8List.fromList(utf8.encode(StlIO.writeAscii(mesh)));
      case 'ply':
        return Uint8List.fromList(utf8.encode(PlyIO.writeAscii(mesh)));
      case 'obj':
        return Uint8List.fromList(utf8.encode(ObjIO.write(mesh)));
      case '3mf':
        return ThreeMfIO.write(mesh);
      case 'mix':
        final name = filename.split('/').last.split('\\').last;
        return MixIO.write(<MixObject>[MixObject(name: name, mesh: mesh)]);
      default:
        throw FormatException('Unsupported export format: $ext');
    }
  }
}
