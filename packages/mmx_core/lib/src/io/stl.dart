import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;

import '../mesh/tri_mesh.dart';

/// Binary and ASCII STL.
class StlIO {
  /// Reads binary STL. Vertices are welded by exact coordinates so shared
  /// corners become shared vertices (STL stores three floats per triangle).
  static TriMesh readBinary(Uint8List bytes) {
    if (bytes.length > 256 * 1024 * 1024) {
      throw const FormatException('STL exceeds size limit');
    }
    if (bytes.length < 84) throw const FormatException('Truncated STL header');
    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint32(80, Endian.little);
    final available = (bytes.length - 84) ~/ 50;
    if (count > available) throw const FormatException('Truncated STL faces');
    if (count > 4000000 || 84 + count * 50 != bytes.length) {
      throw const FormatException('Invalid STL face count');
    }
    final n = count;
    final builder = MeshBuilder();
    final weld = <(double, double, double), int>{};
    int vkey(double x, double y, double z) {
      if (!x.isFinite || !y.isFinite || !z.isFinite) {
        throw const FormatException('Non-finite STL coordinate');
      }
      return weld.putIfAbsent((x, y, z), () => builder.addVertex(x, y, z));
    }

    for (var i = 0; i < n; i++) {
      final off = 84 + i * 50 + 12;
      final ax = bd.getFloat32(off, Endian.little);
      final ay = bd.getFloat32(off + 4, Endian.little);
      final az = bd.getFloat32(off + 8, Endian.little);
      final bx = bd.getFloat32(off + 12, Endian.little);
      final by = bd.getFloat32(off + 16, Endian.little);
      final bz = bd.getFloat32(off + 20, Endian.little);
      final cx = bd.getFloat32(off + 24, Endian.little);
      final cy = bd.getFloat32(off + 28, Endian.little);
      final cz = bd.getFloat32(off + 32, Endian.little);
      builder.addTriangle(vkey(ax, ay, az), vkey(bx, by, bz), vkey(cx, cy, cz));
    }
    final mesh = builder.build();
    mesh.removeDegenerateFaces();
    return mesh;
  }

  static TriMesh readAscii(String text) {
    if (text.length > 256 * 1024 * 1024) {
      throw const FormatException('STL exceeds size limit');
    }
    final builder = MeshBuilder();
    final weld = <(double, double, double), int>{};
    final vertices = <int>[];
    var state = 0, solids = 0;
    for (final raw in LineSplitter.split(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.length > 1048576) {
        throw const FormatException('STL line exceeds limit');
      }
      final words = line.split(RegExp(r'\s+'));
      switch (words.first.toLowerCase()) {
        case 'solid':
          if (state != 0) throw const FormatException('Unexpected STL solid');
          solids++;
          state = 1;
        case 'facet':
          if (state != 1 ||
              words.length != 5 ||
              words[1].toLowerCase() != 'normal') {
            throw const FormatException('Invalid STL facet');
          }
          if (words.skip(2).map(double.parse).any((n) => !n.isFinite)) {
            throw const FormatException('Invalid STL normal');
          }
          if (builder.faceCount >= 4000000) {
            throw const FormatException('STL face limit exceeded');
          }
          state = 2;
        case 'outer':
          if (state != 2 ||
              words.length != 2 ||
              words[1].toLowerCase() != 'loop') {
            throw const FormatException('Invalid STL outer loop');
          }
          state = 3;
        case 'vertex':
          if (state != 3 || words.length != 4 || vertices.length >= 3) {
            throw const FormatException('Invalid STL vertex');
          }
          final x = double.parse(words[1]),
              y = double.parse(words[2]),
              z = double.parse(words[3]);
          if (!x.isFinite || !y.isFinite || !z.isFinite) {
            throw const FormatException('Non-finite STL coordinate');
          }
          vertices.add(
              weld.putIfAbsent((x, y, z), () => builder.addVertex(x, y, z)));
        case 'endloop':
          if (state != 3 || words.length != 1 || vertices.length != 3) {
            throw const FormatException('Invalid STL loop');
          }
          state = 4;
        case 'endfacet':
          if (state != 4 || words.length != 1) {
            throw const FormatException('Invalid STL facet end');
          }
          builder.addTriangle(vertices[0], vertices[1], vertices[2]);
          vertices.clear();
          state = 1;
        case 'endsolid':
          if (state != 1) throw const FormatException('Invalid STL solid end');
          state = 0;
        default:
          throw const FormatException('Unknown STL directive');
      }
    }
    if (solids == 0 || state != 0) {
      throw const FormatException('Truncated STL solid');
    }
    final mesh = builder.build();
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid STL geometry');
    }
    mesh.removeDegenerateFaces();
    return mesh;
  }

  static Uint8List writeBinary(TriMesh mesh) {
    mesh.requireUntextured('STL export');
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid STL geometry');
    }
    final n = mesh.faceCount;
    final out = Uint8List(84 + n * 50);
    final bd = ByteData.sublistView(out);
    final header = 'Binary STL exported by mmx_core'.codeUnits;
    for (var i = 0; i < header.length && i < 80; i++) {
      out[i] = header[i];
    }
    bd.setUint32(80, n, Endian.little);
    for (var f = 0; f < n; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ax = mesh.vx(a), ay = mesh.vy(a), az = mesh.vz(a);
      final bx = mesh.vx(b), by = mesh.vy(b), bz = mesh.vz(b);
      final cx = mesh.vx(c), cy = mesh.vy(c), cz = mesh.vz(c);
      final ux = bx - ax, uy = by - ay, uz = bz - az;
      final wx = cx - ax, wy = cy - ay, wz = cz - az;
      var nx = uy * wz - uz * wy,
          ny = uz * wx - ux * wz,
          nz = ux * wy - uy * wx;
      final len = (nx * nx + ny * ny + nz * nz);
      if (len > 1e-20) {
        final inv = 1.0 / math.sqrt(len);
        nx *= inv;
        ny *= inv;
        nz *= inv;
      }
      final off = 84 + f * 50;
      bd.setFloat32(off, nx, Endian.little);
      bd.setFloat32(off + 4, ny, Endian.little);
      bd.setFloat32(off + 8, nz, Endian.little);
      bd.setFloat32(off + 12, ax, Endian.little);
      bd.setFloat32(off + 16, ay, Endian.little);
      bd.setFloat32(off + 20, az, Endian.little);
      bd.setFloat32(off + 24, bx, Endian.little);
      bd.setFloat32(off + 28, by, Endian.little);
      bd.setFloat32(off + 32, bz, Endian.little);
      bd.setFloat32(off + 36, cx, Endian.little);
      bd.setFloat32(off + 40, cy, Endian.little);
      bd.setFloat32(off + 44, cz, Endian.little);
      bd.setUint16(off + 48, 0, Endian.little);
    }
    return out;
  }

  static String writeAscii(TriMesh mesh, {String name = 'mmx_core'}) {
    mesh.requireUntextured('STL export');
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid STL geometry');
    }
    name = name.replaceAll(RegExp(r'[\r\n]'), ' ');
    final sb = StringBuffer('solid $name\n');
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      sb.writeln('  facet normal 0 0 0');
      sb.writeln('    outer loop');
      sb.writeln('      vertex ${mesh.vx(a)} ${mesh.vy(a)} ${mesh.vz(a)}');
      sb.writeln('      vertex ${mesh.vx(b)} ${mesh.vy(b)} ${mesh.vz(b)}');
      sb.writeln('      vertex ${mesh.vx(c)} ${mesh.vy(c)} ${mesh.vz(c)}');
      sb.writeln('    endloop');
      sb.writeln('  endfacet');
    }
    sb.writeln('endsolid $name');
    return sb.toString();
  }
}
