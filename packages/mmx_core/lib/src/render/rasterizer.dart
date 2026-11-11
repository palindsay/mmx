import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';
import '../mesh/material.dart';
import 'camera.dart';

/// Per-object render input.
class RenderObject {
  final TriMesh mesh;
  final List<double> transform; // column-major 4x4
  final List<double> color; // rgb 0..1
  final Uint8List? faceMask; // selection / highlight
  final Float32List? faceColors; // 3 floats per face (analysis heatmap)
  final bool visible;

  RenderObject(this.mesh,
      {required this.transform,
      required this.color,
      this.faceMask,
      this.faceColors,
      this.visible = true});
}

class RenderOptions {
  final int width;
  final int height;
  final List<double> background;
  final bool wireframe;
  final bool showBed;
  final double bedSize;
  final double? bedWidth, bedDepth;
  final bool centerBed;
  double get actualBedWidth => bedWidth ?? bedSize;
  double get actualBedDepth => bedDepth ?? bedSize;
  double get bedMinX => centerBed ? -actualBedWidth / 2 : 0;
  double get bedMinZ => centerBed ? -actualBedDepth / 2 : 0;
  final bool showGrid;
  final bool flatShading;
  final double ambient;

  const RenderOptions({
    this.width = 960,
    this.height = 640,
    this.background = const <double>[0.10, 0.11, 0.13],
    this.wireframe = false,
    this.showBed = true,
    this.bedSize = 200,
    this.bedWidth,
    this.bedDepth,
    this.centerBed = true,
    this.showGrid = true,
    this.flatShading = true,
    this.ambient = 0.28,
  });
}

/// Software z-buffer rasterizer.
///
/// The shipped Meshmixer binary renders through legacy OpenGL 2.1 with GLSL
/// 1.20 shaders (glBegin/glEnd, client vertex arrays). This renderer produces
/// the same kind of view (flat-shaded surface, per-vertex analysis colouring,
/// selection highlight, cut-plane overlay, print bed) into a plain RGBA buffer
/// so the same code path works on every platform, including inside an isolate.
class Rasterizer {
  static Uint8List render(
      List<RenderObject> objects, Camera camera, RenderOptions opts) {
    final w = opts.width, h = opts.height;
    final color = Uint8List(w * h * 4);
    final depth = Float32List(w * h);
    for (var i = 0; i < w * h; i++) {
      color[i * 4] = (opts.background[0] * 255).round();
      color[i * 4 + 1] = (opts.background[1] * 255).round();
      color[i * 4 + 2] = (opts.background[2] * 255).round();
      color[i * 4 + 3] = 255;
      depth[i] = double.infinity;
    }

    final vp = camera.viewProjection(w / h);
    final eye = camera.position();

    if (opts.showBed || opts.showGrid) {
      _drawBed(color, depth, w, h, vp, camera, opts);
    }

    // Gather triangles with their shading colours, then draw far-to-near so
    // the depth buffer resolves overlaps deterministically.
    for (final obj in objects) {
      if (!obj.visible) continue;
      final mesh = obj.mesh;
      final m = obj.transform;
      final nv = mesh.vertexCount;
      final world = Float64List(nv * 3);
      for (var v = 0; v < nv; v++) {
        final x = mesh.vx(v), y = mesh.vy(v), z = mesh.vz(v);
        world[v * 3] = m[0] * x + m[4] * y + m[8] * z + m[12];
        world[v * 3 + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
        world[v * 3 + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
      }

      for (var f = 0; f < mesh.faceCount; f++) {
        final i0 = mesh.indices[f * 3],
            i1 = mesh.indices[f * 3 + 1],
            i2 = mesh.indices[f * 3 + 2];
        final ax = world[i0 * 3],
            ay = world[i0 * 3 + 1],
            az = world[i0 * 3 + 2];
        final bx = world[i1 * 3],
            by = world[i1 * 3 + 1],
            bz = world[i1 * 3 + 2];
        final cx = world[i2 * 3],
            cy = world[i2 * 3 + 1],
            cz = world[i2 * 3 + 2];
        final ux = bx - ax, uy = by - ay, uz = bz - az;
        final wx = cx - ax, wy = cy - ay, wz = cz - az;
        var nx = uy * wz - uz * wy,
            ny = uz * wx - ux * wz,
            nz = ux * wy - uy * wx;
        final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nl < 1e-20) continue;
        nx /= nl;
        ny /= nl;
        nz /= nl;
        // View vector for backface culling.
        final vx = eye[0] - ax, vy = eye[1] - ay, vz = eye[2] - az;
        if (nx * vx + ny * vy + nz * vz <= 0) continue;

        // Base colour: analysis heatmap, selection tint or material.
        final material = mesh.faceMaterials == null
            ? null
            : mesh.materials[mesh.faceMaterials![f]];
        var r = material?.baseColor[0] ?? obj.color[0],
            g = material?.baseColor[1] ?? obj.color[1],
            b = material?.baseColor[2] ?? obj.color[2];
        final analysis =
            obj.faceColors != null && obj.faceColors!.length >= (f + 1) * 3;
        if (analysis) {
          r = obj.faceColors![f * 3];
          g = obj.faceColors![f * 3 + 1];
          b = obj.faceColors![f * 3 + 2];
        }
        final selected = obj.faceMask != null &&
            f < obj.faceMask!.length &&
            obj.faceMask![f] != 0;

        // Two-light Lambert plus ambient.
        final l1 = _normalize(<double>[0.45, 0.75, 0.5]);
        final l2 = _normalize(<double>[-0.6, 0.2, -0.4]);
        final d1 = math.max(0.0, nx * l1[0] + ny * l1[1] + nz * l1[2]);
        final d2 = math.max(0.0, nx * l2[0] + ny * l2[1] + nz * l2[2]) * 0.35;
        final shade = (opts.ambient + d1 * 0.75 + d2).clamp(0.0, 1.35);
        final cr = r * shade;
        final cg = g * shade;
        final cb = b * shade;

        _drawTriangle(color, depth, w, h, vp, ax, ay, az, bx, by, bz, cx, cy,
            cz, cr, cg, cb, opts.wireframe,
            material: analysis ? null : material,
            selected: selected,
            shade: shade,
            attributes: [
              for (var k = 0; k < 3; k++)
                [
                  mesh.cornerUvs?[f * 6 + k * 2] ?? 0,
                  mesh.cornerUvs?[f * 6 + k * 2 + 1] ?? 0,
                  for (var c = 0; c < 3; c++)
                    analysis
                        ? 1.0
                        : mesh.vertexColors?[mesh.indices[f * 3 + k] * 3 + c] ??
                            1.0
                ]
            ]);
      }
    }
    return color;
  }

  static void _drawTriangle(
      Uint8List color,
      Float32List depth,
      int w,
      int h,
      List<double> vp,
      double ax,
      double ay,
      double az,
      double bx,
      double by,
      double bz,
      double cx,
      double cy,
      double cz,
      double r,
      double g,
      double b,
      bool wireframe,
      {List<List<double>>? attributes,
      MeshMaterial? material,
      bool selected = false,
      double shade = 1}) {
    // Clip-space vertices.
    final p0 = _project(vp, ax, ay, az);
    final p1 = _project(vp, bx, by, bz);
    final p2 = _project(vp, cx, cy, cz);
    if (attributes != null) {
      p0.addAll(attributes[0]);
      p1.addAll(attributes[1]);
      p2.addAll(attributes[2]);
    }
    // Near-plane clip in homogeneous space (z + w >= eps).
    final poly = _clipNear(<List<double>>[p0, p1, p2]);
    if (poly.length < 3) return;
    for (var i = 2; i < poly.length; i++) {
      _rasterizeClipped(
          color, depth, w, h, poly[0], poly[i - 1], poly[i], r, g, b,
          material: material, selected: selected, shade: shade);
    }
    if (wireframe) {
      for (var i = 0; i < poly.length; i++) {
        _line(color, depth, w, h, poly[i], poly[(i + 1) % poly.length], r * 0.4,
            g * 0.4, b * 0.4);
      }
    }
  }

  /// Projects a world point into [x, y, z, w] clip space.
  static List<double> _project(List<double> vp, double x, double y, double z) {
    return <double>[
      vp[0] * x + vp[4] * y + vp[8] * z + vp[12],
      vp[1] * x + vp[5] * y + vp[9] * z + vp[13],
      vp[2] * x + vp[6] * y + vp[10] * z + vp[14],
      vp[3] * x + vp[7] * y + vp[11] * z + vp[15],
    ];
  }

  static List<List<double>> _clipNear(List<List<double>> poly) {
    const eps = 1e-6;
    final out = <List<double>>[];
    for (var i = 0; i < poly.length; i++) {
      final cur = poly[i];
      final nxt = poly[(i + 1) % poly.length];
      final dCur = cur[2] + cur[3] - eps;
      final dNxt = nxt[2] + nxt[3] - eps;
      if (dCur >= 0) out.add(cur);
      if ((dCur >= 0) != (dNxt >= 0)) {
        final t = dCur / (dCur - dNxt);
        out.add([
          for (var k = 0; k < cur.length; k++) cur[k] + (nxt[k] - cur[k]) * t
        ]);
      }
    }
    return out;
  }

  static void _rasterizeClipped(
      Uint8List color,
      Float32List depth,
      int w,
      int h,
      List<double> p0,
      List<double> p1,
      List<double> p2,
      double r,
      double g,
      double b,
      {MeshMaterial? material,
      bool selected = false,
      double shade = 1}) {
    // Perspective divide to screen space.
    final w0 = p0[3] == 0 ? 1e-9 : p0[3];
    final w1 = p1[3] == 0 ? 1e-9 : p1[3];
    final w2 = p2[3] == 0 ? 1e-9 : p2[3];
    final x0 = (p0[0] / w0 * 0.5 + 0.5) * w;
    final y0 = (1 - (p0[1] / w0 * 0.5 + 0.5)) * h;
    final z0 = p0[2] / w0;
    final x1 = (p1[0] / w1 * 0.5 + 0.5) * w;
    final y1 = (1 - (p1[1] / w1 * 0.5 + 0.5)) * h;
    final z1 = p1[2] / w1;
    final x2 = (p2[0] / w2 * 0.5 + 0.5) * w;
    final y2 = (1 - (p2[1] / w2 * 0.5 + 0.5)) * h;
    final z2 = p2[2] / w2;

    var minX = math.min(x0, math.min(x1, x2)).floor();
    var maxX = math.max(x0, math.max(x1, x2)).ceil();
    var minY = math.min(y0, math.min(y1, y2)).floor();
    var maxY = math.max(y0, math.max(y1, y2)).ceil();
    if (minX < 0) minX = 0;
    if (minY < 0) minY = 0;
    if (maxX > w - 1) maxX = w - 1;
    if (maxY > h - 1) maxY = h - 1;
    if (minX > maxX || minY > maxY) return;

    final area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
    if (area.abs() < 1e-9) return;
    final inv = 1.0 / area;
    // Screen-space depth interpolated linearly (z/w is affine in screen space).
    for (var py = minY; py <= maxY; py++) {
      final fy = py + 0.5;
      for (var px = minX; px <= maxX; px++) {
        final fx = px + 0.5;
        final w0b = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) * inv;
        if (w0b < 0) continue;
        final w1b = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) * inv;
        if (w1b < 0) continue;
        final w2b = ((x0 - fx) * (y1 - fy) - (x1 - fx) * (y0 - fy)) * inv;
        if (w2b < 0) continue;
        final z = w0b * z0 + w1b * z1 + w2b * z2;
        final idx = py * w + px;
        if (z >= depth[idx]) continue;
        var cr = r, cg = g, cb = b;
        var alpha = material?.baseColor[3] ?? 1;
        if (p0.length > 4) {
          final denominator = w0b / w0 + w1b / w1 + w2b / w2;
          double attribute(int k) =>
              (w0b * p0[k] / w0 + w1b * p1[k] / w1 + w2b * p2[k] / w2) /
              denominator;
          cr *= attribute(6);
          cg *= attribute(7);
          cb *= attribute(8);
          if (material?.texture != null) {
            final texel = sampleTexture(
                material!.texture!, attribute(4), attribute(5),
                clamp: material.textureClamp);
            cr *= texel.$1;
            cg *= texel.$2;
            cb *= texel.$3;
            alpha *= texel.$4;
          }
        }
        // Both viewport backends deliberately use alpha cutout, not unsorted
        // transparency. Native/OBJ data retain the original alpha values.
        if (alpha < .5) continue;
        if (selected) {
          cr = cr * .35 + .65 * shade;
          cg = cg * .35 + .45 * shade;
          cb = cb * .35 + .10 * shade;
        }
        depth[idx] = z;
        final o = idx * 4;
        color[o] = (cr * 255).round().clamp(0, 255);
        color[o + 1] = (cg * 255).round().clamp(0, 255);
        color[o + 2] = (cb * 255).round().clamp(0, 255);
        color[o + 3] = 255;
      }
    }
  }

  /// Bilinear sRGB sampling with v-up UVs and clamp/repeat addressing. Texel
  /// centers are (i+0.5)/size, matching standard GPU linear samplers.
  static (double, double, double, double) sampleTexture(
      MeshTexture texture, double u, double v,
      {bool clamp = false}) {
    if (!u.isFinite || !v.isFinite) {
      throw ArgumentError('Non-finite texture coordinate');
    }
    u = clamp ? u.clamp(0.0, 1.0) : u - u.floorToDouble();
    v = clamp ? v.clamp(0.0, 1.0) : v - v.floorToDouble();
    final x = u * texture.width - .5, y = (1 - v) * texture.height - .5;
    final ix = x.floor(), iy = y.floor(), fx = x - ix, fy = y - iy;
    int coordinate(int i, int n) => clamp ? i.clamp(0, n - 1) : i % n;
    int offset(int xx, int yy) =>
        (coordinate(yy, texture.height) * texture.width +
            coordinate(xx, texture.width)) *
        4;
    final a = offset(ix, iy),
        bb = offset(ix + 1, iy),
        c = offset(ix, iy + 1),
        d = offset(ix + 1, iy + 1);
    double channel(int k) =>
        ((texture.rgba[a + k] * (1 - fx) + texture.rgba[bb + k] * fx) *
                (1 - fy) +
            (texture.rgba[c + k] * (1 - fx) + texture.rgba[d + k] * fx) * fy) /
        255;
    return (channel(0), channel(1), channel(2), channel(3));
  }

  static void _line(Uint8List color, Float32List depth, int w, int h,
      List<double> p0, List<double> p1, double r, double g, double b) {
    final w0 = p0[3] == 0 ? 1e-9 : p0[3];
    final w1 = p1[3] == 0 ? 1e-9 : p1[3];
    var x0 = (p0[0] / w0 * 0.5 + 0.5) * w;
    var y0 = (1 - (p0[1] / w0 * 0.5 + 0.5)) * h;
    final z0 = p0[2] / w0;
    final x1 = (p1[0] / w1 * 0.5 + 0.5) * w;
    final y1 = (1 - (p1[1] / w1 * 0.5 + 0.5)) * h;
    final z1 = p1[2] / w1;
    final dx = x1 - x0, dy = y1 - y0;
    final steps = math.max(dx.abs(), dy.abs()).ceil();
    if (steps <= 0) return;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final px = (x0 + dx * t).round();
      final py = (y0 + dy * t).round();
      if (px < 0 || py < 0 || px >= w || py >= h) continue;
      final z = z0 + (z1 - z0) * t - 1e-4;
      final idx = py * w + px;
      if (z >= depth[idx]) continue;
      depth[idx] = z;
      final o = idx * 4;
      color[o] = (r * 255).round().clamp(0, 255);
      color[o + 1] = (g * 255).round().clamp(0, 255);
      color[o + 2] = (b * 255).round().clamp(0, 255);
    }
  }

  /// Draws the print bed and a metric grid at y=0.
  static void _drawBed(Uint8List color, Float32List depth, int w, int h,
      List<double> vp, Camera camera, RenderOptions opts) {
    final x0 = opts.bedMinX, z0 = opts.bedMinZ;
    final x1 = x0 + opts.actualBedWidth, z1 = z0 + opts.actualBedDepth;
    if (opts.showGrid) {
      for (var i = 0; i <= 20; i++) {
        final x = x0 + i * opts.actualBedWidth / 20;
        final z = z0 + i * opts.actualBedDepth / 20;
        _worldLine(color, depth, w, h, vp, x, 0, z0, x, 0, z1, .32, .34, .38);
        _worldLine(color, depth, w, h, vp, x0, 0, z, x1, 0, z, .32, .34, .38);
      }
    }
    if (opts.showBed) {
      _worldLine(color, depth, w, h, vp, x0, 0, z0, x1, 0, z0, .55, .58, .62);
      _worldLine(color, depth, w, h, vp, x1, 0, z0, x1, 0, z1, .55, .58, .62);
      _worldLine(color, depth, w, h, vp, x1, 0, z1, x0, 0, z1, .55, .58, .62);
      _worldLine(color, depth, w, h, vp, x0, 0, z1, x0, 0, z0, .55, .58, .62);
    }
    assert(camera.near > 0);
  }

  static void _worldLine(
      Uint8List color,
      Float32List depth,
      int w,
      int h,
      List<double> vp,
      double x0,
      double y0,
      double z0,
      double x1,
      double y1,
      double z1,
      double r,
      double g,
      double b) {
    final p0 = _project(vp, x0, y0, z0);
    final p1 = _project(vp, x1, y1, z1);
    if (p0[3] <= 1e-6 || p1[3] <= 1e-6) return;
    _line(color, depth, w, h, p0, p1, r, g, b);
  }

  static List<double> _normalize(List<double> v) {
    final l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l < 1e-12) return <double>[0, 0, 1];
    return <double>[v[0] / l, v[1] / l, v[2] / l];
  }
}
