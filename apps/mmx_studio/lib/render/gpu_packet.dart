import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';

/// Bounded, versioned little-endian packet consumed by native_renderer.
/// Corner attributes are expanded because UV seams and flat normals need not
/// share the topology's vertex index. Rasterization and depth testing stay GPU.
class GpuPacket {
  static const maximumBytes = 256 * 1024 * 1024;
  static const maximumVertices = 4000000;

  static Uint8List encode(
    List<RenderObject> objects,
    Camera camera,
    RenderOptions options,
  ) {
    validateFrame(options);
    final draws = <_Draw>[];
    var totalVertices = 0;
    var predictedBytes = 104;
    void add(_Draw draw) {
      totalVertices += draw.vertices.length ~/ 16;
      predictedBytes += 152 + draw.vertices.lengthInBytes + draw.rgba.length;
      if (draws.length >= 4096 ||
          totalVertices > maximumVertices ||
          predictedBytes > maximumBytes) {
        throw StateError(
          'GPU scene exceeds bounded draw/vertex/texture budget',
        );
      }
      draws.add(draw);
    }

    if (options.showBed || options.showGrid) {
      _bed(options, add);
    }
    for (final object in objects) {
      if (!object.visible || object.mesh.faceCount == 0) continue;
      final mesh = object.mesh;
      if (mesh.faceCount > (maximumVertices - totalVertices) ~/ 3) {
        throw StateError('GPU geometry exceeds expanded vertex budget');
      }
      if (mesh.validate().isNotEmpty ||
          object.transform.length != 16 ||
          object.transform.any((v) => !v.isFinite) ||
          object.color.length < 3 ||
          object.color.any((v) => !v.isFinite)) {
        throw ArgumentError('Invalid render mesh, transform or color');
      }
      if (object.faceColors != null &&
          object.faceColors!.length != mesh.faceCount * 3) {
        throw ArgumentError('GPU analysis colors require RGB for every face');
      }
      final model = Float32List.fromList(object.transform);
      final (normalMatrix, reflected) = _normalMatrix(model);
      final groups = <int, List<int>>{};
      final analysis = object.faceColors != null;
      for (var f = 0; f < mesh.faceCount; f++) {
        final material = analysis ? -1 : (mesh.faceMaterials?[f] ?? -1);
        groups.putIfAbsent(material, () => []).add(f);
      }
      final smoothNormals = options.flatShading ? null : _smoothNormals(mesh);
      for (final entry in groups.entries) {
        final faces = entry.value;
        final count = faces.length * 3;
        if (totalVertices + count > maximumVertices ||
            predictedBytes + count * 64 > maximumBytes) {
          throw StateError('GPU geometry exceeds vertex budget');
        }
        final material = entry.key >= 0 ? mesh.materials[entry.key] : null;
        final texture = mesh.cornerUvs != null ? material?.texture : null;
        if (predictedBytes + count * 64 + 152 + (texture?.rgba.length ?? 4) >
            maximumBytes) {
          throw StateError('GPU material exceeds packet budget');
        }
        final vertices = Float32List(count * 16);
        var at = 0;
        for (final f in faces) {
          final a = mesh.indices[f * 3],
              b = mesh.indices[f * 3 + 1],
              c = mesh.indices[f * 3 + 2];
          final ux = mesh.vx(b) - mesh.vx(a),
              uy = mesh.vy(b) - mesh.vy(a),
              uz = mesh.vz(b) - mesh.vz(a);
          final wx = mesh.vx(c) - mesh.vx(a),
              wy = mesh.vy(c) - mesh.vy(a),
              wz = mesh.vz(c) - mesh.vz(a);
          final normal = [
            uy * wz - uz * wy,
            uz * wx - ux * wz,
            ux * wy - uy * wx,
          ];
          final length = math.sqrt(
            normal.fold<double>(0, (sum, v) => sum + v * v),
          );
          for (var k = 0; k < 3; k++) {
            final v = mesh.indices[f * 3 + k];
            vertices[at++] = mesh.vx(v);
            vertices[at++] = mesh.vy(v);
            vertices[at++] = mesh.vz(v);
            for (var j = 0; j < 3; j++) {
              vertices[at++] =
                  smoothNormals?[v * 3 + j] ??
                  (length > 0 ? normal[j] / length : (j == 1 ? 1 : 0));
            }
            for (var j = 0; j < 3; j++) {
              final faceColor = object.faceColors;
              vertices[at++] = analysis && faceColor!.length >= f * 3 + 3
                  ? faceColor[f * 3 + j]
                  : (material?.baseColor[j] ?? object.color[j]) *
                        (mesh.vertexColors?[v * 3 + j] ?? 1);
            }
            vertices[at++] = material?.baseColor[3] ?? 1;
            vertices[at++] = mesh.cornerUvs?[f * 6 + k * 2] ?? 0;
            vertices[at++] = mesh.cornerUvs?[f * 6 + k * 2 + 1] ?? 0;
            for (var j = 0; j < 3; j++) {
              vertices[at++] = j == k ? 1 : 0;
            }
            vertices[at++] =
                (object.faceMask != null &&
                    f < object.faceMask!.length &&
                    object.faceMask![f] != 0)
                ? 1
                : 0;
          }
        }
        add(
          _Draw(
            vertices,
            model,
            normalMatrix,
            flags:
                (options.wireframe ? 2 : 0) |
                (reflected ? 4 : 0) |
                ((material?.textureClamp ?? false) ? 8 : 0),
            width: texture?.width ?? 1,
            height: texture?.height ?? 1,
            rgba: texture?.rgba ?? Uint8List.fromList([255, 255, 255, 255]),
          ),
        );
      }
    }
    final writer = _Writer(predictedBytes);
    writer.uint(0x47584d4d);
    writer.uint(1);
    writer.uint(options.width);
    writer.uint(options.height);
    writer.uint(draws.length);
    writer.floats([...options.background.take(3), 1]);
    writer.floats(camera.viewProjection(options.width / options.height));
    writer.floating(options.ambient);
    for (final draw in draws) {
      writer.uint(draw.vertices.length ~/ 16);
      writer.uint(draw.lines ? 1 : 0);
      writer.uint(draw.flags);
      writer.uint(draw.width);
      writer.uint(draw.height);
      writer.uint(draw.rgba.length);
      writer.floats(draw.model);
      writer.floats(draw.normal);
      writer.floats(draw.vertices);
      writer.bytes(draw.rgba);
    }
    return writer.buffer;
  }

  static void validateFrame(RenderOptions options) {
    if (options.width <= 0 ||
        options.height <= 0 ||
        options.width > 4096 ||
        options.height > 4096 ||
        options.background.length != 3 ||
        options.background.any((v) => !v.isFinite || v < 0 || v > 1) ||
        !options.ambient.isFinite ||
        options.ambient < 0 ||
        options.ambient > 1 ||
        !options.actualBedWidth.isFinite ||
        !options.actualBedDepth.isFinite ||
        options.actualBedWidth <= 0 ||
        options.actualBedDepth <= 0) {
      throw ArgumentError('Invalid frame options; maximum size is 4096 × 4096');
    }
  }

  static (Float32List, bool) _normalMatrix(Float32List m) {
    final a = m[0],
        b = m[4],
        c = m[8],
        d = m[1],
        e = m[5],
        f = m[9],
        g = m[2],
        h = m[6],
        i = m[10];
    final determinant =
        a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (!determinant.isFinite ||
        determinant == 0 ||
        m[3] != 0 ||
        m[7] != 0 ||
        m[11] != 0 ||
        m[15] != 1) {
      throw ArgumentError('GPU transform must be nonsingular and affine');
    }
    // Inverse transpose in column-major order; translation is excluded.
    return (
      Float32List.fromList([
        (e * i - f * h) / determinant,
        (c * h - b * i) / determinant,
        (b * f - c * e) / determinant,
        0,
        (f * g - d * i) / determinant,
        (a * i - c * g) / determinant,
        (c * d - a * f) / determinant,
        0,
        (d * h - e * g) / determinant,
        (b * g - a * h) / determinant,
        (a * e - b * d) / determinant,
        0,
        0,
        0,
        0,
        1,
      ]),
      determinant < 0,
    );
  }

  static Float32List _smoothNormals(TriMesh mesh) {
    final result = Float32List(mesh.positions.length);
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ux = mesh.vx(b) - mesh.vx(a),
          uy = mesh.vy(b) - mesh.vy(a),
          uz = mesh.vz(b) - mesh.vz(a);
      final vx = mesh.vx(c) - mesh.vx(a),
          vy = mesh.vy(c) - mesh.vy(a),
          vz = mesh.vz(c) - mesh.vz(a);
      for (final v in [a, b, c]) {
        result[v * 3] += uy * vz - uz * vy;
        result[v * 3 + 1] += uz * vx - ux * vz;
        result[v * 3 + 2] += ux * vy - uy * vx;
      }
    }
    for (var v = 0; v < mesh.vertexCount; v++) {
      final x = result[v * 3], y = result[v * 3 + 1], z = result[v * 3 + 2];
      final length = math.sqrt(x * x + y * y + z * z);
      if (length > 0) {
        for (var k = 0; k < 3; k++) {
          result[v * 3 + k] /= length;
        }
      }
    }
    return result;
  }

  static void _bed(RenderOptions options, void Function(_Draw) add) {
    final x0 = options.bedMinX, z0 = options.bedMinZ;
    final x1 = x0 + options.actualBedWidth, z1 = z0 + options.actualBedDepth;
    final identity = Float32List.fromList(identity4());
    final values = <double>[];
    void vertex(double x, double y, double z, List<double> color) {
      values.addAll([x, y, z, 0, 1, 0, ...color, 1, 0, 0, 1, 0, 0, 0]);
    }

    if (options.showBed) {
      // The bed is a reference outline, not a solid floor: geometry below y=0
      // must remain editable and visible, as in the software rasterizer.
      for (final p in [
        [x0, 0.0, z0],
        [x1, 0.0, z0],
        [x1, 0.0, z0],
        [x1, 0.0, z1],
        [x1, 0.0, z1],
        [x0, 0.0, z1],
        [x0, 0.0, z1],
        [x0, 0.0, z0],
      ]) {
        vertex(p[0], p[1], p[2], [.55, .58, .62]);
      }
      add(
        _Draw(
          Float32List.fromList(values),
          identity,
          identity,
          lines: true,
          flags: 17,
        ),
      );
      values.clear();
    }
    if (options.showGrid) {
      for (var i = 0; i <= 20; i++) {
        final x = x0 + i * options.actualBedWidth / 20;
        final z = z0 + i * options.actualBedDepth / 20;
        for (final p in [
          [x, .005, z0],
          [x, .005, z1],
          [x0, .005, z],
          [x1, .005, z],
        ]) {
          vertex(p[0], p[1], p[2], i == 10 ? [.35, .4, .45] : [.22, .25, .28]);
        }
      }
      add(
        _Draw(
          Float32List.fromList(values),
          identity,
          identity,
          lines: true,
          flags: 17,
        ),
      );
    }
  }
}

class _Draw {
  final Float32List vertices, model, normal;
  final bool lines;
  final int flags, width, height;
  final Uint8List rgba;
  _Draw(
    this.vertices,
    this.model,
    this.normal, {
    this.lines = false,
    this.flags = 0,
    this.width = 1,
    this.height = 1,
    Uint8List? rgba,
  }) : rgba = rgba ?? Uint8List.fromList([255, 255, 255, 255]);
}

class _Writer {
  final Uint8List buffer;
  late final ByteData data = ByteData.sublistView(buffer);
  var at = 0;
  _Writer(int size) : buffer = Uint8List(size);
  void uint(int value) {
    data.setUint32(at, value, Endian.little);
    at += 4;
  }

  void floating(double value) {
    if (!value.isFinite) {
      throw ArgumentError('Non-finite GPU attribute');
    }
    data.setFloat32(at, value, Endian.little);
    at += 4;
  }

  void floats(Iterable<double> values) {
    for (final value in values) {
      floating(value);
    }
  }

  void bytes(Uint8List values) {
    buffer.setRange(at, at + values.length, values);
    at += values.length;
  }
}
