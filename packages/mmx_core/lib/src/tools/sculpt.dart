import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';

enum BrushOp {
  draw,
  drawSharp,
  inflate,
  flatten,
  pinch,
  crease,
  twist,
  smooth,
  move,
  refine,
  reduce,
  attract,
}

/// Face selection sets and the interactive sculpting brushes.
///
/// Observed brush set in the shipped binary (icon resources):
/// drag, draw, draw2, flatten, inflate, pinch, move, spikes, paint, attract,
/// meshRefine, meshReduce, meshReduceNonuniform, zipper, blur. Brush properties
/// are Strength / Spacing / Symmetry / AlignToStroke / Lazyness, with
/// "Toggle Refinement" and "Toggle Adaptive Refinement".
class Selection {
  final Uint8List faceMask;
  final int faceCount;

  Selection(this.faceMask, this.faceCount);

  factory Selection.empty(int faceCount) =>
      Selection(Uint8List(faceCount), faceCount);

  int get count {
    var c = 0;
    for (final v in faceMask) {
      if (v != 0) c++;
    }
    return c;
  }

  bool contains(int face) => faceMask[face] != 0;

  List<int> faces() {
    final out = <int>[];
    for (var f = 0; f < faceMask.length; f++) {
      if (faceMask[f] != 0) out.add(f);
    }
    return out;
  }

  void invert() {
    for (var i = 0; i < faceMask.length; i++) {
      faceMask[i] = faceMask[i] == 0 ? 1 : 0;
    }
  }

  /// One-ring growth of the selection across shared edges.
  void expand(TriMesh mesh) {
    final topo = MeshTopology(mesh);
    final add = <int>[];
    for (var f = 0; f < faceCount; f++) {
      if (faceMask[f] == 0) continue;
      for (var k = 0; k < 3; k++) {
        final a = mesh.indices[f * 3 + k];
        final b = mesh.indices[f * 3 + (k + 1) % 3];
        for (final g in topo.edgeFaces[topo.edgeKey(a, b)] ?? const <int>[]) {
          if (faceMask[g] == 0) add.add(g);
        }
      }
    }
    for (final g in add) {
      faceMask[g] = 1;
    }
  }

  void contract(TriMesh mesh) {
    final topo = MeshTopology(mesh);
    final remove = <int>[];
    for (var f = 0; f < faceCount; f++) {
      if (faceMask[f] == 0) continue;
      for (var k = 0; k < 3; k++) {
        final a = mesh.indices[f * 3 + k];
        final b = mesh.indices[f * 3 + (k + 1) % 3];
        for (final g in topo.edgeFaces[topo.edgeKey(a, b)] ?? const <int>[]) {
          if (faceMask[g] == 0) {
            remove.add(f);
            break;
          }
        }
      }
    }
    for (final f in remove) {
      faceMask[f] = 0;
    }
  }

  /// Grows the selection to every face connected to the current selection.
  void expandToConnected(TriMesh mesh) {
    final topo = MeshTopology(mesh);
    final (comp, _) = topo.components();
    final selectedComps = <int>{};
    for (var f = 0; f < faceCount; f++) {
      if (faceMask[f] != 0) selectedComps.add(comp[f]);
    }
    for (var f = 0; f < faceCount; f++) {
      if (selectedComps.contains(comp[f])) faceMask[f] = 1;
    }
  }

  /// Sphere brush selection, optionally restricted to front-facing faces.
  static Selection sphereBrush(TriMesh mesh, List<double> center, double radius,
      {bool frontFacingOnly = false,
      List<double>? viewDirection,
      double facingBias = 0.0}) {
    final sel = Selection.empty(mesh.faceCount);
    final r2 = radius * radius;
    final cx = center[0], cy = center[1], cz = center[2];
    final vd = viewDirection;
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final fx = (mesh.vx(a) + mesh.vx(b) + mesh.vx(c)) / 3;
      final fy = (mesh.vy(a) + mesh.vy(b) + mesh.vy(c)) / 3;
      final fz = (mesh.vz(a) + mesh.vz(b) + mesh.vz(c)) / 3;
      final dx = fx - cx, dy = fy - cy, dz = fz - cz;
      if (dx * dx + dy * dy + dz * dz > r2) continue;
      if (frontFacingOnly && vd != null) {
        final nx = mesh.vx(b) - mesh.vx(a),
            ny = mesh.vy(b) - mesh.vy(a),
            nz = mesh.vz(b) - mesh.vz(a);
        final wx = mesh.vx(c) - mesh.vx(a),
            wy = mesh.vy(c) - mesh.vy(a),
            wz = mesh.vz(c) - mesh.vz(a);
        final fnx = ny * wz - nz * wy,
            fny = nz * wx - nx * wz,
            fnz = nx * wy - ny * wx;
        final l = math.sqrt(fnx * fnx + fny * fny + fnz * fnz);
        if (l > 1e-20) {
          final dot = (fnx * vd[0] + fny * vd[1] + fnz * vd[2]) / l;
          if (dot < -facingBias) continue;
        }
      }
      sel.faceMask[f] = 1;
    }
    return sel;
  }
}

/// Interactive sculpting with dynamic refinement.
class Sculptor {
  static TriMesh apply(
    TriMesh mesh, {
    required BrushOp op,
    required List<double> center,
    required double radius,
    required double strength,
    List<double>? direction,
    bool refine = false,
    bool preserveBoundary = true,
    double symmetryPlaneX = 0,
    bool symmetry = false,
  }) {
    if ((refine &&
            [BrushOp.draw, BrushOp.inflate, BrushOp.flatten].contains(op)) ||
        op == BrushOp.reduce) {
      mesh.requireUntextured('Dynamic sculpt topology');
    }
    var work = mesh.clone();
    if (refine &&
        (op == BrushOp.draw ||
            op == BrushOp.inflate ||
            op == BrushOp.flatten)) {
      work = _refineRegion(work, center, radius, radius / 6.0);
    }
    final topo = MeshTopology(work);
    final boundary = <int>{};
    if (preserveBoundary) {
      for (final e in topo.boundaryEdges()) {
        boundary.add(e[0]);
        boundary.add(e[1]);
      }
    }
    final normals = _vertexNormals(work, topo);
    final r = radius;
    final cx = center[0], cy = center[1], cz = center[2];
    final dx0 = direction?[0] ?? 0.0;
    final dy0 = direction?[1] ?? 0.0;
    final dz0 = direction?[2] ?? 0.0;

    // Twist axis: the supplied direction, else the surface normal nearest the
    // brush centre (Meshmixer twists around the local surface normal).
    var axX = dx0, axY = dy0, axZ = dz0;
    if (op == BrushOp.twist) {
      if (axX == 0 && axY == 0 && axZ == 0) {
        var best = -1;
        var bestD = double.infinity;
        for (var v = 0; v < work.vertexCount; v++) {
          final d = _dist(work, v, cx, cy, cz);
          if (d < bestD) {
            bestD = d;
            best = v;
          }
        }
        if (best >= 0) {
          axX = normals[best * 3];
          axY = normals[best * 3 + 1];
          axZ = normals[best * 3 + 2];
        }
      }
      final l = math.sqrt(axX * axX + axY * axY + axZ * axZ);
      if (l > 1e-12) {
        axX /= l;
        axY /= l;
        axZ /= l;
      }
    }

    // Flatten plane: average of selected vertices.
    var px = 0.0, py = 0.0, pz = 0.0, pn = 0.0;
    var fnx = 0.0, fny = 0.0, fnz = 0.0;
    if (op == BrushOp.flatten) {
      for (var v = 0; v < work.vertexCount; v++) {
        final d = _dist(work, v, cx, cy, cz);
        if (d > r) continue;
        px += work.vx(v);
        py += work.vy(v);
        pz += work.vz(v);
        pn++;
        fnx += normals[v * 3];
        fny += normals[v * 3 + 1];
        fnz += normals[v * 3 + 2];
      }
      if (pn > 0) {
        px /= pn;
        py /= pn;
        pz /= pn;
        final l = math.sqrt(fnx * fnx + fny * fny + fnz * fnz);
        if (l > 1e-12) {
          fnx /= l;
          fny /= l;
          fnz /= l;
        }
      }
    }

    final next = Float32List.fromList(work.positions);
    void applyAt(double ccx, double ccy, double ccz) {
      for (var v = 0; v < work.vertexCount; v++) {
        if (preserveBoundary && boundary.contains(v)) continue;
        final d = _dist(work, v, ccx, ccy, ccz);
        if (d > r) continue;
        final w = _falloff(d / r) * strength;
        final vx = next[v * 3], vy = next[v * 3 + 1], vz = next[v * 3 + 2];
        switch (op) {
          case BrushOp.draw:
          case BrushOp.drawSharp:
            final sharp = op == BrushOp.drawSharp ? w * w : w;
            next[v * 3] = vx + normals[v * 3] * sharp * r * 0.25;
            next[v * 3 + 1] = vy + normals[v * 3 + 1] * sharp * r * 0.25;
            next[v * 3 + 2] = vz + normals[v * 3 + 2] * sharp * r * 0.25;
          case BrushOp.inflate:
            next[v * 3] = vx + normals[v * 3] * w * r * 0.25;
            next[v * 3 + 1] = vy + normals[v * 3 + 1] * w * r * 0.25;
            next[v * 3 + 2] = vz + normals[v * 3 + 2] * w * r * 0.25;
          case BrushOp.flatten:
            if (pn == 0) break;
            final s = (vx - px) * fnx + (vy - py) * fny + (vz - pz) * fnz;
            next[v * 3] = vx - fnx * s * w;
            next[v * 3 + 1] = vy - fny * s * w;
            next[v * 3 + 2] = vz - fnz * s * w;
          case BrushOp.pinch:
            final toX = ccx - vx, toY = ccy - vy, toZ = ccz - vz;
            next[v * 3] = vx + toX * w * 0.3;
            next[v * 3 + 1] = vy + toY * w * 0.3;
            next[v * 3 + 2] = vz + toZ * w * 0.3;
          case BrushOp.crease:
            final nx = normals[v * 3],
                ny = normals[v * 3 + 1],
                nz = normals[v * 3 + 2];
            final toX = ccx - vx, toY = ccy - vy, toZ = ccz - vz;
            final dn = toX * nx + toY * ny + toZ * nz;
            next[v * 3] = vx + (toX - nx * dn) * w * 0.35 + nx * w * r * 0.12;
            next[v * 3 + 1] =
                vy + (toY - ny * dn) * w * 0.35 + ny * w * r * 0.12;
            next[v * 3 + 2] =
                vz + (toZ - nz * dn) * w * 0.35 + nz * w * r * 0.12;
          case BrushOp.twist:
            {
              final qx = vx - ccx, qy = vy - ccy, qz = vz - ccz;
              final ang = w * 0.6;
              final c = math.cos(ang), s = math.sin(ang);
              final dot = qx * axX + qy * axY + qz * axZ;
              final crX = axY * qz - axZ * qy;
              final crY = axZ * qx - axX * qz;
              final crZ = axX * qy - axY * qx;
              next[v * 3] = ccx + qx * c + crX * s + axX * dot * (1 - c);
              next[v * 3 + 1] = ccy + qy * c + crY * s + axY * dot * (1 - c);
              next[v * 3 + 2] = ccz + qz * c + crZ * s + axZ * dot * (1 - c);
            }
          case BrushOp.move:
            next[v * 3] = vx + dx0 * w;
            next[v * 3 + 1] = vy + dy0 * w;
            next[v * 3 + 2] = vz + dz0 * w;
          case BrushOp.smooth:
          case BrushOp.attract:
            final nb = topo.neighborsOfVertex(v);
            if (nb.isEmpty) break;
            var sx = 0.0, sy = 0.0, sz = 0.0;
            for (final nv in nb) {
              sx += work.vx(nv);
              sy += work.vy(nv);
              sz += work.vz(nv);
            }
            final k = nb.length;
            next[v * 3] = vx + (sx / k - vx) * w;
            next[v * 3 + 1] = vy + (sy / k - vy) * w;
            next[v * 3 + 2] = vz + (sz / k - vz) * w;
          case BrushOp.refine:
          case BrushOp.reduce:
            break;
        }
      }
    }

    applyAt(cx, cy, cz);
    if (symmetry) {
      applyAt(2 * symmetryPlaneX - cx, cy, cz);
    }
    work.positions = next;

    if (op == BrushOp.reduce) {
      work = _reduceRegion(work, center, radius, r / 5.0);
    }
    return work;
  }

  static double _dist(TriMesh m, int v, double x, double y, double z) {
    final dx = m.vx(v) - x, dy = m.vy(v) - y, dz = m.vz(v) - z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  static double _falloff(double t) {
    if (t >= 1) return 0;
    final s = 1 - t;
    return s * s * (3 - 2 * s);
  }

  /// Splits edges inside the brush so sculpting has enough resolution.
  static TriMesh _refineRegion(
      TriMesh mesh, List<double> center, double radius, double maxEdge) {
    final builder = MeshBuilder();
    final vmap = List<int>.generate(mesh.vertexCount,
        (v) => builder.addVertex(mesh.vx(v), mesh.vy(v), mesh.vz(v)));
    final cache = <int, int>{};
    final n = mesh.vertexCount;
    int mid(int a, int b) {
      final key = a < b ? a * n + b : b * n + a;
      final c = cache[key];
      if (c != null) return c;
      final id = builder.addVertex((mesh.vx(a) + mesh.vx(b)) * 0.5,
          (mesh.vy(a) + mesh.vy(b)) * 0.5, (mesh.vz(a) + mesh.vz(b)) * 0.5);
      cache[key] = id;
      return id;
    }

    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final fx = (mesh.vx(a) + mesh.vx(b) + mesh.vx(c)) / 3;
      final fy = (mesh.vy(a) + mesh.vy(b) + mesh.vy(c)) / 3;
      final fz = (mesh.vz(a) + mesh.vz(b) + mesh.vz(c)) / 3;
      final d = math.sqrt((fx - center[0]) * (fx - center[0]) +
          (fy - center[1]) * (fy - center[1]) +
          (fz - center[2]) * (fz - center[2]));
      if (d > radius) {
        builder.addTriangle(vmap[a], vmap[b], vmap[c]);
        continue;
      }
      final ab = _edgeLen(mesh, a, b) > maxEdge;
      final bc = _edgeLen(mesh, b, c) > maxEdge;
      final ca = _edgeLen(mesh, c, a) > maxEdge;
      final count = (ab ? 1 : 0) + (bc ? 1 : 0) + (ca ? 1 : 0);
      if (count == 0) {
        builder.addTriangle(vmap[a], vmap[b], vmap[c]);
      } else if (count == 1) {
        if (ab) {
          final m = mid(a, b);
          builder.addTriangle(vmap[a], m, vmap[c]);
          builder.addTriangle(m, vmap[b], vmap[c]);
        } else if (bc) {
          final m = mid(b, c);
          builder.addTriangle(vmap[a], vmap[b], m);
          builder.addTriangle(vmap[a], m, vmap[c]);
        } else {
          final m = mid(c, a);
          builder.addTriangle(vmap[a], vmap[b], m);
          builder.addTriangle(m, vmap[b], vmap[c]);
        }
      } else {
        final m1 = mid(a, b), m2 = mid(b, c), m3 = mid(c, a);
        builder.addTriangle(vmap[a], m1, m3);
        builder.addTriangle(m1, vmap[b], m2);
        builder.addTriangle(m2, vmap[c], m3);
        builder.addTriangle(m1, m2, m3);
      }
    }
    return builder.build();
  }

  /// Collapses edges inside the brush that are shorter than [minEdge].
  static TriMesh _reduceRegion(
      TriMesh mesh, List<double> center, double radius, double minEdge) {
    final topo = MeshTopology(mesh);
    final parent = Int32List(mesh.vertexCount);
    for (var i = 0; i < parent.length; i++) {
      parent[i] = i;
    }
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    for (final key in topo.edgeFaces.keys) {
      final n = mesh.vertexCount;
      final a = key ~/ n, b = key % n;
      final mx = (mesh.vx(a) + mesh.vx(b)) / 2;
      final my = (mesh.vy(a) + mesh.vy(b)) / 2;
      final mz = (mesh.vz(a) + mesh.vz(b)) / 2;
      final d = math.sqrt((mx - center[0]) * (mx - center[0]) +
          (my - center[1]) * (my - center[1]) +
          (mz - center[2]) * (mz - center[2]));
      if (d > radius) continue;
      if (_edgeLen(mesh, a, b) > minEdge) continue;
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }
    final builder = MeshBuilder();
    final map = Int32List(mesh.vertexCount);
    for (var v = 0; v < mesh.vertexCount; v++) {
      if (find(v) == v) {
        map[v] = builder.addVertex(mesh.vx(v), mesh.vy(v), mesh.vz(v));
      }
    }
    for (var v = 0; v < mesh.vertexCount; v++) {
      final r = find(v);
      if (r != v) map[v] = map[r];
    }
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = map[find(mesh.indices[f * 3])];
      final b = map[find(mesh.indices[f * 3 + 1])];
      final c = map[find(mesh.indices[f * 3 + 2])];
      if (a == b || b == c || a == c) continue;
      builder.addTriangle(a, b, c);
    }
    final out = builder.build();
    out.removeDegenerateFaces();
    out.compact();
    return out;
  }

  static double _edgeLen(TriMesh m, int a, int b) {
    final dx = m.vx(a) - m.vx(b),
        dy = m.vy(a) - m.vy(b),
        dz = m.vz(a) - m.vz(b);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  static Float32List _vertexNormals(TriMesh m, MeshTopology topo) {
    final out = Float32List(m.vertexCount * 3);
    for (var v = 0; v < m.vertexCount; v++) {
      var nx = 0.0, ny = 0.0, nz = 0.0;
      for (final f in topo.facesOfVertex(v)) {
        final a = m.indices[f * 3],
            b = m.indices[f * 3 + 1],
            c = m.indices[f * 3 + 2];
        final ux = m.vx(b) - m.vx(a),
            uy = m.vy(b) - m.vy(a),
            uz = m.vz(b) - m.vz(a);
        final wx = m.vx(c) - m.vx(a),
            wy = m.vy(c) - m.vy(a),
            wz = m.vz(c) - m.vz(a);
        nx += uy * wz - uz * wy;
        ny += uz * wx - ux * wz;
        nz += ux * wy - uy * wx;
      }
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l > 1e-20) {
        out[v * 3] = nx / l;
        out[v * 3 + 1] = ny / l;
        out[v * 3 + 2] = nz / l;
      } else {
        out[v * 3 + 2] = 1;
      }
    }
    return out;
  }
}

/// Face-group segmentation by dihedral angle, matching
/// "Generate Face Groups" (Edge Angle / Normal Angle / Size Threshold).
class FaceGroups {
  static Uint16List generate(TriMesh mesh,
      {double angleThresholdDegrees = 30, int minGroupSize = 10}) {
    final topo = MeshTopology(mesh);
    final cosLimit = math.cos(angleThresholdDegrees * math.pi / 180);
    final groups = Uint16List(mesh.faceCount);
    final parent = Int32List(mesh.faceCount);
    for (var i = 0; i < parent.length; i++) {
      parent[i] = i;
    }
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    final normals = <List<double>>[];
    for (var f = 0; f < mesh.faceCount; f++) {
      normals.add(_normal(mesh, f));
    }
    for (final entry in topo.edgeFaces.entries) {
      if (entry.value.length != 2) continue;
      final f0 = entry.value[0], f1 = entry.value[1];
      final d = normals[f0][0] * normals[f1][0] +
          normals[f0][1] * normals[f1][1] +
          normals[f0][2] * normals[f1][2];
      if (d > cosLimit) union(f0, f1);
    }
    final rootToGroup = <int, int>{};
    final sizes = <int, int>{};
    for (var f = 0; f < mesh.faceCount; f++) {
      final r = find(f);
      final g = rootToGroup.putIfAbsent(r, () => rootToGroup.length + 1);
      groups[f] = g;
      sizes[g] = (sizes[g] ?? 0) + 1;
    }
    // Merge tiny groups into their largest neighbour group.
    for (var f = 0; f < mesh.faceCount; f++) {
      if ((sizes[groups[f]] ?? 0) >= minGroupSize) continue;
      for (var k = 0; k < 3; k++) {
        final a = mesh.indices[f * 3 + k];
        final b = mesh.indices[f * 3 + (k + 1) % 3];
        for (final g in topo.edgeFaces[topo.edgeKey(a, b)] ?? const <int>[]) {
          if ((sizes[groups[g]] ?? 0) >= minGroupSize) {
            groups[f] = groups[g];
            break;
          }
        }
      }
    }
    return groups;
  }

  static List<double> _normal(TriMesh m, int f) {
    final a = m.indices[f * 3],
        b = m.indices[f * 3 + 1],
        c = m.indices[f * 3 + 2];
    final ux = m.vx(b) - m.vx(a),
        uy = m.vy(b) - m.vy(a),
        uz = m.vz(b) - m.vz(a);
    final wx = m.vx(c) - m.vx(a),
        wy = m.vy(c) - m.vy(a),
        wz = m.vz(c) - m.vz(a);
    var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-20) return <double>[0, 0, 1];
    return <double>[nx / l, ny / l, nz / l];
  }
}

/// Soft transform: weighted translation with a falloff, followed by a
/// relaxation pass so the boundary blends into the surrounding surface.
class SoftTransform {
  static TriMesh translate(
      TriMesh mesh, List<double> center, double radius, List<double> delta,
      {int relaxIterations = 6}) {
    final topo = MeshTopology(mesh);
    final next = Float32List.fromList(mesh.positions);
    for (var v = 0; v < mesh.vertexCount; v++) {
      final dx = mesh.vx(v) - center[0];
      final dy = mesh.vy(v) - center[1];
      final dz = mesh.vz(v) - center[2];
      final d = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (d > radius) continue;
      final w = Sculptor._falloff(d / radius);
      next[v * 3] = mesh.vx(v) + delta[0] * w;
      next[v * 3 + 1] = mesh.vy(v) + delta[1] * w;
      next[v * 3 + 2] = mesh.vz(v) + delta[2] * w;
    }
    mesh.positions = next;
    if (relaxIterations <= 0) return mesh;
    // Relax the transition band only.
    for (var it = 0; it < relaxIterations; it++) {
      final relaxed = Float32List.fromList(mesh.positions);
      for (var v = 0; v < mesh.vertexCount; v++) {
        final dx = mesh.vx(v) - center[0];
        final dy = mesh.vy(v) - center[1];
        final dz = mesh.vz(v) - center[2];
        final d = math.sqrt(dx * dx + dy * dy + dz * dz);
        if (d < radius * 0.5 || d > radius) continue;
        final nb = topo.neighborsOfVertex(v);
        if (nb.isEmpty) continue;
        var sx = 0.0, sy = 0.0, sz = 0.0;
        for (final w in nb) {
          sx += mesh.vx(w);
          sy += mesh.vy(w);
          sz += mesh.vz(w);
        }
        final k = nb.length;
        relaxed[v * 3] = 0.5 * mesh.vx(v) + 0.5 * sx / k;
        relaxed[v * 3 + 1] = 0.5 * mesh.vy(v) + 0.5 * sy / k;
        relaxed[v * 3 + 2] = 0.5 * mesh.vz(v) + 0.5 * sz / k;
      }
      mesh.positions = relaxed;
    }
    return mesh;
  }
}
