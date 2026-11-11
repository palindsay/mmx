import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../mesh/material.dart';
import '../mesh/tri_mesh.dart';
import 'asset_path.dart';
import 'texture.dart';
import 'zip.dart';

const materialNamespace =
    'http://schemas.microsoft.com/3dmanufacturing/material/2015/02';
String _attribute(String name, String value) =>
    XmlAttribute(XmlName.parts(name), value).toXmlString();
int _integer(XmlElement e, String name) {
  final value = int.tryParse(e.getAttribute(name) ?? '');
  if (value == null || value < 0) throw FormatException('Invalid 3MF $name');
  return value;
}

List<double> _color(String value) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(value)) {
    throw const FormatException('Invalid 3MF display color');
  }
  return [
    for (var i = 1; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16) / 255,
    if (value.length == 7) 1
  ];
}

/// The diffuse subset of the published 3MF core/materials specifications.
/// Composite/PBR resources, color gradients and mixed texture addressing reject.
class ThreeMfMaterials {
  final groups = <int, List<MeshMaterial>>{};
  final coordinates = <int, Float32List>{};
  final colors = <int, List<List<double>>>{};
  final allIds = <int>{};
  ThreeMfMaterials(XmlElement resources, Map<String, Uint8List> files) {
    final textures = <int, MeshMaterial>{};
    final imageCache = <String, MeshTexture>{};
    var imageBudget = 0, coordinateCount = 0, baseCount = 0, colorCount = 0;
    for (final e in resources.childElements) {
      final id = _integer(e, 'id');
      if (id == 0 || !allIds.add(id) || allIds.length > 16384) {
        throw const FormatException('Duplicate or excessive 3MF resource IDs');
      }
      if (e.getAttribute('displaypropertiesid') != null) {
        throw const FormatException('3MF display/PBR properties unsupported');
      }
      switch (e.name.local) {
        case 'object':
        case 'texture2dgroup':
          break;
        case 'basematerials':
          final materials = <MeshMaterial>[];
          for (final b in e.childElements) {
            if (b.name.local != 'base' || ++baseCount > 4096) {
              throw const FormatException('Invalid 3MF base material');
            }
            materials.add(MeshMaterial(
                name: b.getAttribute('name') ?? 'material',
                baseColor: _color(b.getAttribute('displaycolor') ?? '')));
          }
          groups[id] = materials;
        case 'colorgroup':
          final values = <List<double>>[];
          for (final c in e.childElements) {
            if (c.name.local != 'color' || ++colorCount > 2000000) {
              throw const FormatException('Invalid 3MF color group');
            }
            final value = _color(c.getAttribute('color') ?? '');
            if (value[3] != 1) {
              throw const FormatException(
                  '3MF transparent color groups unsupported');
            }
            values.add(value.take(3).toList());
          }
          colors[id] = values;
        case 'texture2d':
          var path = e.getAttribute('path') ?? '';
          path = safeAssetPath(Uri.decodeComponent(
              path.startsWith('/') ? path.substring(1) : path));
          final u = e.getAttribute('tilestyleu') ?? 'wrap',
              v = e.getAttribute('tilestylev') ?? 'wrap';
          if (u != v ||
              !['wrap', 'clamp'].contains(u) ||
              !['auto', 'linear']
                  .contains(e.getAttribute('filter') ?? 'auto')) {
            throw const FormatException(
                'Unsupported 3MF texture addressing/filter');
          }
          final image = imageCache.putIfAbsent(path, () {
            final data = files[path];
            if (data == null) {
              throw const FormatException('Missing 3MF texture part');
            }
            final texture = TextureIO.decode(data,
                name: path.split('/').last,
                maxDecodedBytes: 192 * 1024 * 1024 - imageBudget);
            if ((imageBudget += texture.byteSize) > 192 * 1024 * 1024) {
              throw const FormatException('3MF texture budget exceeded');
            }
            return texture;
          });
          if (image.mimeType != e.getAttribute('contenttype')) {
            throw const FormatException('3MF texture content type mismatch');
          }
          textures[id] = MeshMaterial(
              name: path.split('/').last,
              texture: image,
              textureClamp: u == 'clamp');
        default:
          throw FormatException('Unsupported 3MF resource: ${e.name.local}');
      }
    }
    for (final e in resources.childElements
        .where((e) => e.name.local == 'texture2dgroup')) {
      final material = textures[_integer(e, 'texid')];
      if (material == null) {
        throw const FormatException('Missing 3MF texture resource');
      }
      final uv = <double>[];
      for (final c in e.childElements) {
        if (c.name.local != 'tex2coord' || ++coordinateCount > 12000000) {
          throw const FormatException('Invalid or excessive 3MF UVs');
        }
        final u = double.tryParse(c.getAttribute('u') ?? ''),
            v = double.tryParse(c.getAttribute('v') ?? '');
        if (u == null || v == null || !u.isFinite || !v.isFinite) {
          throw const FormatException('Invalid 3MF UV');
        }
        uv.addAll([u, v]);
      }
      final id = _integer(e, 'id');
      groups[id] = [material];
      coordinates[id] = Float32List.fromList(uv);
    }
  }
}

class ThreeMfSurfaceBuilder {
  final ThreeMfMaterials resources;
  final XmlElement object;
  final materials = <MeshMaterial>[];
  final _materialIds = <MeshMaterial, int>{};
  final _faces = <int>[], _uvs = <double>[];
  final _vertexColors = <int, List<double>>{};
  var _textured = false,
      _assigned = false,
      _colorized = false,
      _unassigned = false;
  final _defaultMaterial = MeshMaterial(name: 'unassigned');
  ThreeMfSurfaceBuilder(this.resources, this.object);
  void add(XmlElement triangle, List<int> vertices) {
    final pid = triangle.getAttribute('pid') ?? object.getAttribute('pid');
    final first = triangle.getAttribute('p1') ?? object.getAttribute('pindex');
    MeshMaterial material = _defaultMaterial;
    var uv = const <double>[0, 0, 0, 0, 0, 0];
    if (pid != null) {
      final groupId = int.tryParse(pid), p1 = int.tryParse(first ?? '');
      final group = resources.groups[groupId];
      final colorGroup = resources.colors[groupId];
      final p2 = int.tryParse(triangle.getAttribute('p2') ?? first ?? ''),
          p3 = int.tryParse(triangle.getAttribute('p3') ?? first ?? '');
      if ((group == null && colorGroup == null) ||
          p1 == null ||
          p2 == null ||
          p3 == null ||
          [p1, p2, p3].any((p) => p < 0)) {
        throw const FormatException('Invalid 3MF property reference');
      }
      final coords = resources.coordinates[groupId];
      if (colorGroup != null) {
        if (_assigned ||
            _unassigned ||
            [p1, p2, p3].any((p) => p >= colorGroup.length)) {
          throw const FormatException(
              'Unsupported mixed or invalid 3MF colors');
        }
        _colorized = true;
        final ids = [p1, p2, p3];
        for (var k = 0; k < 3; k++) {
          final color = colorGroup[ids[k]],
              previous = _vertexColors[vertices[k]];
          if (previous != null &&
              List.generate(3, (c) => previous[c] != color[c]).any((v) => v)) {
            throw const FormatException(
                '3MF per-corner color seams unsupported');
          }
          _vertexColors[vertices[k]] = color;
        }
      } else if (coords != null) {
        if ([p1, p2, p3].any((p) => p >= coords.length ~/ 2)) {
          throw const FormatException('3MF UV index out of range');
        }
        material = group!.single;
        _textured = true;
        uv = [
          for (final p in [p1, p2, p3]) ...[coords[p * 2], coords[p * 2 + 1]]
        ];
      } else {
        if (p1 != p2 || p1 != p3 || p1 >= group!.length) {
          throw const FormatException('3MF material gradients unsupported');
        }
        material = group[p1];
      }
      if (colorGroup == null) {
        if (_colorized) {
          throw const FormatException(
              'Mixed 3MF color/material properties unsupported');
        }
        _assigned = true;
      }
    } else if (first != null ||
        triangle.getAttribute('p2') != null ||
        triangle.getAttribute('p3') != null) {
      throw const FormatException('3MF properties have no resource');
    } else {
      if (_colorized) {
        throw const FormatException(
            'Mixed unassigned/color 3MF faces unsupported');
      }
      _unassigned = true;
    }
    _faces.add(_materialIds.putIfAbsent(material, () {
      if (materials.length >= 4096) {
        throw const FormatException('3MF material limit exceeded');
      }
      materials.add(material);
      return materials.length - 1;
    }));
    _uvs.addAll(uv);
  }

  TriMesh finish(TriMesh mesh) {
    if (_assigned) {
      mesh.materials = materials;
      mesh.faceMaterials = Uint16List.fromList(_faces);
    }
    if (_textured) mesh.cornerUvs = Float32List.fromList(_uvs);
    if (_colorized) {
      final colors = Float32List(mesh.vertexCount * 3)
        ..fillRange(0, mesh.vertexCount * 3, 1);
      for (final entry in _vertexColors.entries) {
        colors.setRange(entry.key * 3, entry.key * 3 + 3, entry.value);
      }
      mesh.vertexColors = colors;
    }
    return mesh;
  }
}

class ThreeMfSurfaceWriter {
  final TriMesh mesh;
  final resources = StringBuffer();
  final textures = <ZipEntry>[];
  final Int32List _uvIndices;
  ThreeMfSurfaceWriter(this.mesh)
      : _uvIndices =
            Int32List(mesh.cornerUvs == null ? 0 : mesh.indices.length) {
    if (mesh.vertexColors != null && mesh.materials.isNotEmpty) {
      throw const FormatException(
          '3MF combined vertex colors/materials unsupported; use OBJ/native');
    }
    if (mesh.vertexColors != null) {
      final used = Uint8List(mesh.vertexCount);
      for (final v in mesh.indices) {
        used[v] = 1;
      }
      if (used.contains(0)) {
        throw const FormatException(
            '3MF cannot assign colors to unused vertices; use OBJ/native');
      }
      if (mesh.vertexColors!.any((v) => v < 0 || v > 1)) {
        throw const FormatException('3MF RGB outside [0,1]');
      }
      resources.writeln('<m:colorgroup id="2">');
      for (var v = 0; v < mesh.vertexCount; v++) {
        final color = '#${[
          for (var k = 0; k < 3; k++)
            (mesh.vertexColors![v * 3 + k] * 255)
                .round()
                .toRadixString(16)
                .padLeft(2, '0')
        ].join()}';
        resources.writeln('<m:color color="$color"/>');
      }
      resources.writeln('</m:colorgroup>');
    }
    final corners = <int, List<int>>{};
    for (var f = 0; f < mesh.faceCount; f++) {
      final id = mesh.faceMaterials?[f];
      if (id != null && mesh.materials[id].texture != null) {
        (corners[id] ??= []).addAll([f * 3, f * 3 + 1, f * 3 + 2]);
      } else if (mesh.cornerUvs != null &&
          Iterable<int>.generate(6)
              .any((k) => mesh.cornerUvs![f * 6 + k] != 0)) {
        throw const FormatException(
            '3MF cannot store UVs on untextured faces; use OBJ/native');
      }
    }
    if (mesh.cornerUvs != null && corners.isEmpty) {
      throw const FormatException(
          '3MF cannot store UVs without a textured face; use OBJ/native');
    }
    for (var i = 0; i < mesh.materials.length; i++) {
      final m = mesh.materials[i], id = i * 3 + 2;
      if (m.texture == null) {
        final color =
            '#${m.baseColor.map((v) => (v * 255).round().toRadixString(16).padLeft(2, '0')).join()}';
        resources.writeln(
            '<basematerials id="$id"><base ${_attribute('name', m.name)} displaycolor="$color"/></basematerials>');
      } else {
        if (m.baseColor.any((v) => v != 1)) {
          throw const FormatException(
              '3MF tinted texture export is unsupported; use OBJ/native');
        }
        TextureIO.validateSource(m.texture!);
        final path =
            '3D/Textures/material_$i.${m.texture!.mimeType == 'image/png' ? 'png' : 'jpg'}';
        textures.add(ZipEntry(path, m.texture!.bytes));
        final mode = m.textureClamp ? 'clamp' : 'wrap';
        resources.writeln(
            '<m:texture2d id="${id + 1}" path="/$path" contenttype="${m.texture!.mimeType}" tilestyleu="$mode" tilestylev="$mode" filter="linear"/>');
        resources.writeln('<m:texture2dgroup id="$id" texid="${id + 1}">');
        var n = 0;
        for (final c in corners[i] ?? <int>[]) {
          _uvIndices[c] = n++;
          resources.writeln(
              '<m:tex2coord u="${mesh.cornerUvs![c * 2]}" v="${mesh.cornerUvs![c * 2 + 1]}"/>');
        }
        resources.writeln('</m:texture2dgroup>');
      }
    }
  }
  String triangle(int face) {
    if (mesh.vertexColors != null) {
      return ' pid="2" p1="${mesh.indices[face * 3]}" p2="${mesh.indices[face * 3 + 1]}" p3="${mesh.indices[face * 3 + 2]}"';
    }
    final index = mesh.faceMaterials?[face];
    if (index == null) return '';
    final id = index * 3 + 2;
    if (mesh.materials[index].texture == null) return ' pid="$id" p1="0"';
    return ' pid="$id" p1="${_uvIndices[face * 3]}" p2="${_uvIndices[face * 3 + 1]}" p3="${_uvIndices[face * 3 + 2]}"';
  }
}
