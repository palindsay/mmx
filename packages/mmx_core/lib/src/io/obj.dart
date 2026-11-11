import 'dart:typed_data';
import 'dart:convert';
import 'polygon_triangulation.dart';
import 'asset_path.dart';
import 'mtl.dart';
import 'texture.dart';
import '../mesh/material.dart';

import '../mesh/tri_mesh.dart';

/// Wavefront OBJ import/export. Supports negative indices, polygon faces
/// (ear-clipped), and per-object/group segmentation.
class ObjIO {
  static TriMesh read(String text,
      {bool keepGroups = true,
      Uint8List Function(String relativePath)? readAsset}) {
    if (text.length > 256 * 1024 * 1024) {
      throw const FormatException('OBJ exceeds size limit');
    }
    final positions = <double>[], colors = <double>[];
    final indices = <int>[], groupIds = <int>[];
    final groupNames = <String, int>{};
    final texcoords = <double>[], cornerUvs = <double>[];
    final materialIds = <int>[];
    final library = <String, MeshMaterial>{};
    final materialNames = <String, int>{};
    final materials = <MeshMaterial>[];
    final textureLibrary = TextureLibrary();
    var currentMaterial = -1, anyUv = false, missingUv = false;
    var currentGroup = 0, anyColor = false;
    int resolve(String token) {
      final n = int.tryParse(token.split('/').first);
      if (n == null || n == 0) {
        throw const FormatException('Invalid OBJ vertex index');
      }
      final i = n > 0 ? n - 1 : positions.length ~/ 3 + n;
      if (i < 0 || i >= positions.length ~/ 3) {
        throw const FormatException('Invalid OBJ vertex index');
      }
      return i;
    }

    for (final raw
        in LineSplitter.split(text.replaceAll(RegExp(r'\\\r?\n'), ' '))) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      if (line.length > 1024 * 1024) {
        throw const FormatException('OBJ line exceeds size limit');
      }
      final parts = line.split(RegExp(r'\s+'));
      switch (parts[0]) {
        case 'mtllib':
          if (readAsset == null) {
            throw const FormatException(
                'OBJ references MTL companions; use MeshIO.readFile or supply readAsset');
          }
          var path = line.substring(parts[0].length).trim();
          if (path.startsWith('"') && path.endsWith('"')) {
            path = path.substring(1, path.length - 1);
          }
          path = safeAssetPath(path);
          final parent = path.contains('/')
              ? path.substring(0, path.lastIndexOf('/') + 1)
              : '';
          final imported = MtlIO.read(utf8.decode(readAsset(path)),
              readAsset: readAsset,
              directory: parent,
              textures: textureLibrary);
          for (final entry in imported.entries) {
            if (library.containsKey(entry.key)) {
              throw const FormatException('Duplicate OBJ material name');
            }
            library[entry.key] = entry.value;
          }
        case 'usemtl':
          // MTL material names preserve internal whitespace. Splitting and
          // rejoining here would make our own exported names unresolvable.
          final name = line.substring(parts[0].length).trim();
          final material = library[name];
          if (material == null) {
            throw FormatException('Missing OBJ material: $name');
          }
          currentMaterial = materialNames.putIfAbsent(name, () {
            if (materials.length >= 4096) {
              throw const FormatException('OBJ material limit exceeded');
            }
            materials.add(material);
            return materials.length - 1;
          });
        case 'vt':
          if (parts.length < 3 ||
              parts.length > 4 ||
              texcoords.length >= 24000000) {
            throw const FormatException('Invalid OBJ UV');
          }
          final values = parts.skip(1).map(double.parse).toList();
          if (values.any((v) => !v.isFinite) ||
              (values.length == 3 && values[2] != 0)) {
            throw const FormatException('Unsupported OBJ UV coordinate');
          }
          texcoords.addAll(values.take(2));
        case 'vn':
          // Shading normals are recomputed from geometry; geometric data is intact.
          if (parts.length != 4 ||
              parts
                  .skip(1)
                  .any((p) => !(double.tryParse(p)?.isFinite ?? false))) {
            throw const FormatException('Invalid OBJ normal');
          }
        case 'v':
          if (positions.length >= 6000000 ||
              ![4, 5, 7].contains(parts.length)) {
            throw const FormatException(
                'Invalid OBJ vertex or vertex limit exceeded');
          }
          final values = parts.skip(1).map(double.parse).toList();
          if (values.any((v) => !v.isFinite)) {
            throw const FormatException('Non-finite OBJ vertex');
          }
          final w = parts.length == 5 ? values[3] : 1.0;
          if (w == 0) {
            throw const FormatException('Zero homogeneous OBJ coordinate');
          }
          positions.addAll(values.take(3).map((v) => v / w));
          if (parts.length == 7) {
            final rgb = values.skip(3).toList();
            if (rgb.any((v) => v < 0 || v > 1)) {
              throw const FormatException('OBJ color outside [0,1]');
            }
            colors.addAll(rgb);
            anyColor = true;
          } else {
            colors.addAll([1, 1, 1]);
          }
        case 'g':
        case 'o':
          if (keepGroups && parts.length > 1) {
            final name = parts.sublist(1).join(' ');
            final encoded = RegExp(r'^group_(\d+)$').firstMatch(name);
            final group = encoded == null
                ? groupNames.putIfAbsent(name, () => groupNames.length + 1)
                : int.parse(encoded.group(1)!);
            if (group > 65535) {
              throw const FormatException('OBJ face group limit exceeded');
            }
            currentGroup = group;
          }
        case 'f':
          if (parts.length < 4 || parts.length > 4097) {
            throw const FormatException('Invalid OBJ polygon');
          }
          final face = parts.skip(1).map(resolve).toList();
          final triangles = triangulatePolygon(positions, face);
          if (indices.length + triangles.length > 12000000) {
            throw const FormatException('OBJ triangle limit exceeded');
          }
          indices.addAll(triangles);
          groupIds
              .addAll(List<int>.filled(triangles.length ~/ 3, currentGroup));
          final faceUvs = <int>[];
          for (final token in parts.skip(1)) {
            final fields = token.split('/');
            if (fields.length > 3) {
              throw const FormatException('Invalid OBJ face token');
            }
            if (fields.length > 1 && fields[1].isNotEmpty) {
              final n = int.tryParse(fields[1]);
              final uv = n == null
                  ? -1
                  : n > 0
                      ? n - 1
                      : texcoords.length ~/ 2 + n;
              if (n == 0 || uv < 0 || uv >= texcoords.length ~/ 2) {
                throw const FormatException('OBJ texture index out of range');
              }
              faceUvs.add(uv);
              anyUv = true;
            } else {
              faceUvs.add(-1);
              missingUv = true;
            }
          }
          for (final v in triangles) {
            final uv = faceUvs[face.indexOf(v)];
            cornerUvs.addAll(
                uv < 0 ? [0, 0] : texcoords.sublist(uv * 2, uv * 2 + 2));
          }
          materialIds
              .addAll(List.filled(triangles.length ~/ 3, currentMaterial));
      }
    }
    if (anyUv && missingUv) {
      throw const FormatException(
          'Mixed mapped/unmapped OBJ corners are unsupported');
    }
    if (materials.isNotEmpty && materialIds.any((id) => id < 0)) {
      materials.add(MeshMaterial(name: 'unassigned'));
      for (var i = 0; i < materialIds.length; i++) {
        if (materialIds[i] < 0) materialIds[i] = materials.length - 1;
      }
    }
    final mesh = TriMesh(
        Float32List.fromList(positions), Uint32List.fromList(indices),
        vertexColors: anyColor ? Float32List.fromList(colors) : null,
        cornerUvs: anyUv ? Float32List.fromList(cornerUvs) : null,
        faceMaterials:
            materials.isEmpty ? null : Uint16List.fromList(materialIds),
        materials: materials,
        faceGroups: keepGroups && groupIds.isNotEmpty
            ? Uint16List.fromList(groupIds)
            : null);
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid OBJ geometry');
    }
    mesh.removeDegenerateFaces();
    return mesh;
  }

  static String write(TriMesh mesh,
      {String name = 'mesh',
      bool writeGroups = true,
      String? materialLibrary}) {
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid OBJ geometry');
    }
    name = name.replaceAll(RegExp(r'[\r\n]'), ' ');
    final sb = StringBuffer('# exported by mmx_core\n');
    final labels = _materialLabels(mesh);
    if (mesh.materials.isNotEmpty) {
      if (materialLibrary == null) {
        throw const FormatException(
            'OBJ materials require companion export; use ObjIO.writeBundle');
      }
      sb.writeln('mtllib ${safeAssetPath(materialLibrary)}');
    }
    for (var i = 0; i < mesh.vertexCount; i++) {
      sb.write('v ${mesh.vx(i)} ${mesh.vy(i)} ${mesh.vz(i)}');
      if (mesh.vertexColors != null) {
        sb.write(
            ' ${mesh.vertexColors![i * 3]} ${mesh.vertexColors![i * 3 + 1]} ${mesh.vertexColors![i * 3 + 2]}');
      }
      sb.writeln();
    }
    if (mesh.cornerUvs != null) {
      for (var i = 0; i < mesh.cornerUvs!.length; i += 2) {
        sb.writeln('vt ${mesh.cornerUvs![i]} ${mesh.cornerUvs![i + 1]}');
      }
    }
    var lastGroup = -1, lastMaterial = -1;
    for (var f = 0; f < mesh.faceCount; f++) {
      if (writeGroups &&
          mesh.faceGroups != null &&
          lastGroup != mesh.faceGroups![f]) {
        lastGroup = mesh.faceGroups![f];
        sb.writeln('g group_$lastGroup');
      }
      if (mesh.faceMaterials != null &&
          lastMaterial != mesh.faceMaterials![f]) {
        lastMaterial = mesh.faceMaterials![f];
        sb.writeln('usemtl ${labels[lastMaterial]}');
      }
      sb.writeln('f ${List.generate(3, (k) {
        final c = f * 3 + k;
        return '${mesh.indices[c] + 1}${mesh.cornerUvs == null ? '' : '/${c + 1}'}';
      }).join(' ')}');
    }
    return sb.toString();
  }

  /// Relative companion paths and bytes, suitable for a single export directory.
  static Map<String, Uint8List> writeBundle(TriMesh mesh,
      {String filename = 'mesh.obj', String? materialLibraryReference}) {
    filename = safeAssetPath(filename);
    if (filename.contains('/')) {
      throw const FormatException('OBJ bundle filename must be a basename');
    }
    final stem = filename.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final mtlName = '$stem.mtl';
    final out = <String, Uint8List>{};
    final mtl = StringBuffer('# diffuse materials exported by mmx_core\n');
    final labels = _materialLabels(mesh);
    for (var i = 0; i < mesh.materials.length; i++) {
      final m = mesh.materials[i], c = m.baseColor;
      mtl.writeln(
          'newmtl ${labels[i]}\nKd ${c[0]} ${c[1]} ${c[2]}\nd ${c[3]}\nillum 1');
      if (m.texture != null) {
        TextureIO.validateSource(m.texture!);
        final path =
            '${stem}_texture_$i.${m.texture!.mimeType == 'image/png' ? 'png' : 'jpg'}';
        out[path] = m.texture!.bytes;
        mtl.writeln('map_Kd -clamp ${m.textureClamp ? 'on' : 'off'} $path');
      }
    }
    if (mesh.materials.isNotEmpty) {
      out[mtlName] = Uint8List.fromList(utf8.encode(mtl.toString()));
    }
    out[filename] = Uint8List.fromList(utf8.encode(
        write(mesh, materialLibrary: materialLibraryReference ?? mtlName)));
    return out;
  }

  static List<String> _materialLabels(TriMesh mesh) {
    final used = <String>{}, labels = <String>[];
    for (var i = 0; i < mesh.materials.length; i++) {
      var name = mesh.materials[i].name;
      if (name.isEmpty ||
          name.trim() != name ||
          name.contains(RegExp(r'[\r\n#]')) ||
          used.contains(name)) {
        name = 'material_$i';
      }
      while (!used.add(name)) {
        name = '${name}_';
      }
      labels.add(name);
    }
    return labels;
  }
}
