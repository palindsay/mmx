import 'dart:convert';
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';
import 'polygon_triangulation.dart';

/// Schema-driven PLY 1.0 reader: ASCII and both binary byte orders. Unknown
/// elements/properties are consumed using their declared scalar/list types.
class PlyIO {
  static const _maxVertices = 2000000, _maxFaces = 4000000;
  static const _sizes = <String, int>{
    'char': 1,
    'uchar': 1,
    'short': 2,
    'ushort': 2,
    'int': 4,
    'uint': 4,
    'float': 4,
    'double': 8
  };
  static const _aliases = <String, String>{
    'int8': 'char',
    'uint8': 'uchar',
    'int16': 'short',
    'uint16': 'ushort',
    'int32': 'int',
    'uint32': 'uint',
    'float32': 'float',
    'float64': 'double'
  };
  static String _type(String name) {
    final t = _aliases[name] ?? name;
    if (!_sizes.containsKey(t)) {
      throw FormatException('Unsupported PLY scalar type: $name');
    }
    return t;
  }

  static TriMesh read(Uint8List bytes) {
    if (bytes.length > 256 * 1024 * 1024) {
      throw const FormatException('PLY exceeds size limit');
    }
    var offset = 0;
    String line() {
      final start = offset;
      while (offset < bytes.length && bytes[offset] != 10) {
        if (++offset > 1024 * 1024) {
          throw const FormatException('PLY header exceeds size limit');
        }
      }
      if (offset == bytes.length) {
        throw const FormatException('Truncated PLY header');
      }
      return ascii.decode(bytes.sublist(start, offset++)).trim();
    }

    if (line() != 'ply') throw const FormatException('Invalid PLY signature');
    String? format;
    final elements = <_Element>[];
    var rows = 0;
    while (true) {
      final words = line().split(RegExp(r'\s+'));
      if (words.first == 'end_header') break;
      switch (words.first) {
        case 'comment':
        case 'obj_info':
        case '':
          break;
        case 'format':
          if (format != null ||
              words.length != 3 ||
              words[2] != '1.0' ||
              !['ascii', 'binary_little_endian', 'binary_big_endian']
                  .contains(words[1])) {
            throw const FormatException('Unsupported PLY format');
          }
          format = words[1];
        case 'element':
          if (words.length != 3 ||
              elements.length >= 64 ||
              elements.any((e) => e.name == words[1])) {
            throw const FormatException('Invalid PLY element');
          }
          final n = int.tryParse(words[2]);
          if (n == null || n < 0 || n > _maxFaces || (rows += n) > 8000000) {
            throw const FormatException('PLY element count exceeds limit');
          }
          elements.add(_Element(words[1], n));
        case 'property':
          if (elements.isEmpty || elements.last.properties.length >= 64) {
            throw const FormatException('Invalid PLY property');
          }
          late _Property prop;
          if (words.length == 3) {
            prop = _Property(words[2], _type(words[1]));
          } else if (words.length == 5 && words[1] == 'list') {
            final count = _type(words[2]);
            if (count == 'float' || count == 'double') {
              throw const FormatException('PLY list counts must be integers');
            }
            prop = _Property(words[4], _type(words[3]), count);
          } else {
            throw const FormatException('Invalid PLY property declaration');
          }
          if (elements.last.properties.any((p) => p.name == prop.name)) {
            throw const FormatException('Duplicate PLY property');
          }
          elements.last.properties.add(prop);
        default:
          throw const FormatException('Unknown PLY header directive');
      }
    }
    if (format == null) throw const FormatException('Missing PLY format');
    final vertex = elements.where((e) => e.name == 'vertex').firstOrNull;
    if (vertex == null ||
        vertex.count > _maxVertices ||
        !['x', 'y', 'z'].every((n) =>
            vertex.properties.any((p) => p.name == n && p.countType == null))) {
      throw const FormatException('Missing PLY vertex coordinates');
    }
    final face = elements.where((e) => e.name == 'face').firstOrNull;
    if (face != null && face.count > 0) {
      final indexProperties = face.properties
          .where((p) => ['vertex_indices', 'vertex_index'].contains(p.name))
          .toList();
      if (indexProperties.length != 1 ||
          indexProperties.single.countType == null ||
          ['float', 'double'].contains(indexProperties.single.type)) {
        throw const FormatException('Missing or ambiguous PLY face indices');
      }
    }
    var minimumBytes = 0;
    for (final e in elements) {
      if (e.count > 0 && e.properties.isEmpty) {
        throw const FormatException('Empty PLY schema');
      }
      minimumBytes += e.count *
          e.properties.fold<int>(
              0,
              (n, p) =>
                  n + (format == 'ascii' ? 1 : _sizes[p.countType ?? p.type]!));
    }
    if (minimumBytes > bytes.length - offset) {
      throw const FormatException('Truncated PLY body');
    }
    final data = ByteData.sublistView(bytes);
    final endian = format == 'binary_big_endian' ? Endian.big : Endian.little;
    num scalar(String type) {
      num value;
      if (format == 'ascii') {
        while (offset < bytes.length && bytes[offset] <= 32) {
          offset++;
        }
        final start = offset;
        while (offset < bytes.length && bytes[offset] > 32) {
          offset++;
        }
        if (offset == start || offset - start > 128) {
          throw const FormatException('Invalid PLY number');
        }
        final token = ascii.decode(bytes.sublist(start, offset));
        final parsed = type == 'float' || type == 'double'
            ? double.tryParse(token)
            : int.tryParse(token);
        if (parsed == null) throw const FormatException('Invalid PLY number');
        value = parsed;
      } else {
        final size = _sizes[type]!;
        if (offset > bytes.length - size) {
          throw const FormatException('Truncated PLY value');
        }
        value = switch (type) {
          'char' => data.getInt8(offset),
          'uchar' => data.getUint8(offset),
          'short' => data.getInt16(offset, endian),
          'ushort' => data.getUint16(offset, endian),
          'int' => data.getInt32(offset, endian),
          'uint' => data.getUint32(offset, endian),
          'float' => data.getFloat32(offset, endian),
          _ => data.getFloat64(offset, endian)
        };
        offset += size;
      }
      final range = switch (type) {
        'char' => (-128, 127),
        'uchar' => (0, 255),
        'short' => (-32768, 32767),
        'ushort' => (0, 65535),
        'int' => (-2147483648, 2147483647),
        'uint' => (0, 4294967295),
        _ => null
      };
      if (!value.isFinite ||
          (range != null && (value < range.$1 || value > range.$2))) {
        throw const FormatException('PLY number outside declared range');
      }
      return value;
    }

    final positions = Float32List(vertex.count * 3);
    final colored = ['red', 'green', 'blue'].every((n) =>
        vertex.properties.any((p) => p.name == n && p.countType == null));
    final colors = colored ? Float32List(vertex.count * 3) : null;
    final polygons = <List<int>>[];
    final groups = <int>[];
    var listItems = 0;
    for (final e in elements) {
      for (var row = 0; row < e.count; row++) {
        List<int>? polygon;
        var group = 0;
        for (final p in e.properties) {
          if (p.countType != null) {
            final count = scalar(p.countType!).toInt();
            if (count < 0 ||
                count > 4096 ||
                (listItems += count) > 16000000 ||
                count > bytes.length - offset) {
              throw const FormatException('PLY list exceeds limit');
            }
            final indices = e.name == 'face' &&
                ['vertex_indices', 'vertex_index'].contains(p.name);
            if (indices) polygon = <int>[];
            for (var i = 0; i < count; i++) {
              final v = scalar(p.type);
              if (indices) polygon!.add(v.toInt());
            }
          } else {
            final value = scalar(p.type);
            if (e.name == 'vertex') {
              final coordinate = ['x', 'y', 'z'].indexOf(p.name);
              if (coordinate >= 0) {
                positions[row * 3 + coordinate] = value.toDouble();
              }
              final color = ['red', 'green', 'blue'].indexOf(p.name);
              if (color >= 0 && colors != null) {
                final normalized = value /
                    (p.type == 'uchar'
                        ? 255
                        : p.type == 'ushort'
                            ? 65535
                            : 1);
                if (normalized < 0 || normalized > 1) {
                  throw const FormatException('PLY color outside range');
                }
                colors[row * 3 + color] = normalized;
              }
            } else if (e.name == 'face' && p.name == 'group_id') {
              if (value != value.toInt() || value < 0 || value > 65535) {
                throw const FormatException('Invalid PLY group');
              }
              group = value.toInt();
            }
          }
        }
        if (e.name == 'face') {
          polygons.add(polygon!);
          groups.add(group);
        }
      }
    }
    if (format == 'ascii') {
      while (offset < bytes.length && bytes[offset] <= 32) {
        offset++;
      }
    }
    if (offset != bytes.length) {
      throw const FormatException('Unexpected data after PLY elements');
    }
    final indices = <int>[], faceGroups = <int>[];
    for (var i = 0; i < polygons.length; i++) {
      final triangles = triangulatePolygon(positions, polygons[i]);
      if (indices.length + triangles.length > _maxFaces * 3) {
        throw const FormatException('PLY triangle count exceeds limit');
      }
      indices.addAll(triangles);
      faceGroups.addAll(List.filled(triangles.length ~/ 3, groups[i]));
    }
    final mesh = TriMesh(positions, Uint32List.fromList(indices),
        vertexColors: colors,
        faceGroups: face?.properties.any((p) => p.name == 'group_id') == true
            ? Uint16List.fromList(faceGroups)
            : null);
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid PLY geometry');
    }
    return mesh;
  }

  static String writeAscii(TriMesh mesh, {String name = 'mesh'}) {
    mesh.requireUntextured('PLY export');
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid PLY geometry');
    }
    final sb =
        StringBuffer('ply\nformat ascii 1.0\ncomment exported by mmx_core\n');
    sb.writeln('element vertex ${mesh.vertexCount}');
    sb.writeln('property float x\nproperty float y\nproperty float z');
    if (mesh.vertexColors != null) {
      sb.writeln(
          'property float red\nproperty float green\nproperty float blue');
    }
    sb.writeln('element face ${mesh.faceCount}');
    sb.writeln('property list uchar int vertex_indices');
    if (mesh.faceGroups != null) sb.writeln('property ushort group_id');
    sb.writeln('end_header');
    for (var i = 0; i < mesh.vertexCount; i++) {
      sb.write('${mesh.vx(i)} ${mesh.vy(i)} ${mesh.vz(i)}');
      if (mesh.vertexColors != null) {
        sb.write(
            ' ${mesh.vertexColors![i * 3]} ${mesh.vertexColors![i * 3 + 1]} ${mesh.vertexColors![i * 3 + 2]}');
      }
      sb.writeln();
    }
    for (var f = 0; f < mesh.faceCount; f++) {
      sb.write(
          '3 ${mesh.indices[f * 3]} ${mesh.indices[f * 3 + 1]} ${mesh.indices[f * 3 + 2]}');
      if (mesh.faceGroups != null) sb.write(' ${mesh.faceGroups![f]}');
      sb.writeln();
    }
    return sb.toString();
  }
}

class _Element {
  final String name;
  final int count;
  final properties = <_Property>[];
  _Element(this.name, this.count);
}

class _Property {
  final String name, type;
  final String? countType;
  _Property(this.name, this.type, [this.countType]);
}
