import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';

enum HoleFillMode { flatMinimal, flatRemeshed, smooth, fixed }

/// Boundary-loop hole filling.
///
/// Observed in the shipped binary: SimpleHoleFiller.cpp, LoopStitcher.cpp,
/// BoundaryJoiner/Stitcher/Bridge operators, and fill types
/// "Flat Minimal | Flat Remeshed | Smooth MVC". This implements minimal-area
/// triangulation plus optional Laplacian relaxation for the smooth mode.
class HoleFiller {
  static TriMesh fill(TriMesh mesh,
      {double maxLoopLength = double.infinity,
      HoleFillMode mode = HoleFillMode.flatMinimal,
      int smoothIterations = 30,
      Set<int>? loopIndices,
      bool requireAll = false}) {
    mesh.requireUntextured('Hole filling');
    final topo = MeshTopology(mesh);
    final loops = topo.boundaryLoops();
    if (loops.isEmpty) return mesh;

    if (maxLoopLength.isNaN ||
        maxLoopLength < 0 ||
        smoothIterations < 0 ||
        smoothIterations > 1000 ||
        (loopIndices != null &&
            loopIndices.any((i) => i < 0 || i >= loops.length))) {
      throw ArgumentError('Invalid hole-fill settings');
    }
    final positions = <double>[...mesh.positions];
    final colors =
        mesh.vertexColors == null ? null : <double>[...mesh.vertexColors!];
    final indices = <int>[...mesh.indices];
    final groups = mesh.faceGroups == null ? null : <int>[...mesh.faceGroups!];
    var added = 0;
    final filledVertices = <int>{};

    for (var loopIndex = 0; loopIndex < loops.length; loopIndex++) {
      if (loopIndices != null && !loopIndices.contains(loopIndex)) continue;
      final loop = loops[loopIndex];
      if (loop.length < 3) continue;
      var perimeter = 0.0;
      for (var i = 0; i < loop.length; i++) {
        final a = loop[i], b = loop[(i + 1) % loop.length];
        final dx = mesh.vx(a) - mesh.vx(b);
        final dy = mesh.vy(a) - mesh.vy(b);
        final dz = mesh.vz(a) - mesh.vz(b);
        perimeter += math.sqrt(dx * dx + dy * dy + dz * dz);
      }
      if (perimeter > maxLoopLength) continue;

      // Desired fill normal = average of the incident face normals.
      var nx = 0.0, ny = 0.0, nz = 0.0;
      for (var i = 0; i < loop.length; i++) {
        final a = loop[i], b = loop[(i + 1) % loop.length];
        final k = topo.edgeKey(a, b);
        final faces = topo.edgeFaces[k];
        if (faces == null) continue;
        for (final f in faces) {
          final fa = mesh.indices[f * 3],
              fb = mesh.indices[f * 3 + 1],
              fc = mesh.indices[f * 3 + 2];
          final ux = mesh.vx(fb) - mesh.vx(fa),
              uy = mesh.vy(fb) - mesh.vy(fa),
              uz = mesh.vz(fb) - mesh.vz(fa);
          final wx = mesh.vx(fc) - mesh.vx(fa),
              wy = mesh.vy(fc) - mesh.vy(fa),
              wz = mesh.vz(fc) - mesh.vz(fa);
          nx += uy * wz - uz * wy;
          ny += uz * wx - ux * wz;
          nz += ux * wy - uy * wx;
        }
      }
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-12) {
        // Degenerate: use the loop's own Newell normal.
        var cx = 0.0, cy = 0.0, cz = 0.0;
        for (var i = 0; i < loop.length; i++) {
          final a = loop[i], b = loop[(i + 1) % loop.length];
          cx += (mesh.vy(a) - mesh.vy(b)) * (mesh.vz(a) + mesh.vz(b));
          cy += (mesh.vz(a) - mesh.vz(b)) * (mesh.vx(a) + mesh.vx(b));
          cz += (mesh.vx(a) - mesh.vx(b)) * (mesh.vy(a) + mesh.vy(b));
        }
        nx = cx;
        ny = cy;
        nz = cz;
      } else {
        nx /= nl;
        ny /= nl;
        nz /= nl;
      }

      // Build an orthonormal basis on the fill plane.
      var refx = 0.0, refy = 0.0, refz = 0.0;
      if (nx.abs() < 0.9) {
        refx = 0;
        refy = -nz;
        refz = ny;
      } else {
        refx = nz;
        refy = 0;
        refz = -nx;
      }
      final rl = math.sqrt(refx * refx + refy * refy + refz * refz);
      refx /= rl;
      refy /= rl;
      refz /= rl;
      final bx = ny * refz - nz * refy,
          by = nz * refx - nx * refz,
          bz = nx * refy - ny * refx;

      // Project loop to 2D.
      final ox = mesh.vx(loop[0]), oy = mesh.vy(loop[0]), oz = mesh.vz(loop[0]);
      final pts = <List<double>>[];
      for (final v in loop) {
        final dx = mesh.vx(v) - ox, dy = mesh.vy(v) - oy, dz = mesh.vz(v) - oz;
        pts.add(<double>[
          dx * refx + dy * refy + dz * refz,
          dx * bx + dy * by + dz * bz,
        ]);
      }
      final area2 = _signedArea(pts);
      final wantCcw = area2 > 0;
      final tris = _earClip(pts, wantCcw);
      if (tris.length != loop.length - 2) {
        if (requireAll) {
          throw StateError(
              'Cannot fill ambiguous boundary; repair or bridge it manually');
        }
        continue;
      }
      if (tris.isEmpty) continue;

      final edgeFaces =
          topo.edgeFaces[topo.edgeKey(loop[0], loop[1])] ?? const <int>[];
      var flip = false;
      for (final f in edgeFaces) {
        for (var k = 0; k < 3; k++) {
          if (mesh.indices[f * 3 + k] == loop[0] &&
              mesh.indices[f * 3 + (k + 1) % 3] == loop[1]) {
            flip = true;
          }
        }
      }
      for (final t in tris) {
        final a = loop[t[0]], b = loop[t[1]], c = loop[t[2]];
        if (mode == HoleFillMode.smooth || mode == HoleFillMode.flatRemeshed) {
          final center = positions.length ~/ 3;
          for (var k = 0; k < 3; k++) {
            positions.add((mesh.positions[a * 3 + k] +
                    mesh.positions[b * 3 + k] +
                    mesh.positions[c * 3 + k]) /
                3);
            colors?.add((mesh.vertexColors![a * 3 + k] +
                    mesh.vertexColors![b * 3 + k] +
                    mesh.vertexColors![c * 3 + k]) /
                3);
          }
          filledVertices.add(center);
          for (final edge in [
            [a, b],
            [b, c],
            [c, a]
          ]) {
            indices.addAll(
                flip ? [edge[1], edge[0], center] : [edge[0], edge[1], center]);
            groups?.add(0);
            added++;
          }
        } else {
          indices.addAll(flip ? [a, c, b] : [a, b, c]);
          groups?.add(0);
          added++;
        }
      }
    }

    final out = TriMesh(
        Float32List.fromList(positions), Uint32List.fromList(indices),
        faceGroups: groups == null ? null : Uint16List.fromList(groups),
        vertexColors: colors == null ? null : Float32List.fromList(colors));
    if (mode == HoleFillMode.smooth && added > 0) {
      _relax(out, smoothIterations, movable: filledVertices);
    }
    return out;
  }

  static double _signedArea(List<List<double>> pts) {
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      s += a[0] * b[1] - b[0] * a[1];
    }
    return s * 0.5;
  }

  /// Area-minimizing ear clipping. [ccw] selects the output winding.
  static List<List<int>> _earClip(List<List<double>> pts, bool ccw) {
    final n = pts.length;
    if (n < 3) return <List<int>>[];
    final idx = List<int>.generate(n, (i) => i);
    if (!ccw) {
      // Reverse so the working polygon is CCW.
      final rev = idx.reversed.toList();
      idx.setAll(0, rev);
    }
    final out = <List<int>>[];
    var guard = 0;
    while (idx.length > 3 && guard++ < n * n) {
      var best = -1;
      var bestScore = double.infinity;
      for (var i = 0; i < idx.length; i++) {
        final prev = idx[(i - 1 + idx.length) % idx.length];
        final cur = idx[i];
        final next = idx[(i + 1) % idx.length];
        if (!_isConvex(pts, prev, cur, next)) continue;
        if (_containsAny(pts, idx, prev, cur, next)) continue;
        final score = _triArea(pts[prev], pts[cur], pts[next]);
        if (score < bestScore) {
          bestScore = score;
          best = i;
        }
      }
      if (best < 0) break;
      final prev = idx[(best - 1 + idx.length) % idx.length];
      final cur = idx[best];
      final next = idx[(best + 1) % idx.length];
      out.add(<int>[prev, cur, next]);
      idx.removeAt(best);
    }
    if (idx.length == 3) {
      out.add(<int>[idx[0], idx[1], idx[2]]);
    }
    if (!ccw) {
      for (final t in out) {
        final tmp = t[1];
        t[1] = t[2];
        t[2] = tmp;
      }
    }
    return out;
  }

  static bool _isConvex(List<List<double>> p, int a, int b, int c) {
    final ax = p[b][0] - p[a][0], ay = p[b][1] - p[a][1];
    final bx = p[c][0] - p[b][0], by = p[c][1] - p[b][1];
    return ax * by - ay * bx > 0;
  }

  static bool _containsAny(
      List<List<double>> p, List<int> idx, int a, int b, int c) {
    for (final i in idx) {
      if (i == a || i == b || i == c) continue;
      if (_pointInTriangle(p[i], p[a], p[b], p[c])) return true;
    }
    return false;
  }

  static bool _pointInTriangle(
      List<double> p, List<double> a, List<double> b, List<double> c) {
    double sign(List<double> p1, List<double> p2, List<double> p3) =>
        (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1]);
    final d1 = sign(p, a, b), d2 = sign(p, b, c), d3 = sign(p, c, a);
    final hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    final hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
    return !(hasNeg && hasPos);
  }

  static double _triArea(List<double> a, List<double> b, List<double> c) {
    return ((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]))
            .abs() *
        0.5;
  }

  /// Laplacian relaxation restricted to the fill patch. When [movable] is
  /// supplied only those vertices move; otherwise all non-boundary vertices do.
  static void _relax(TriMesh mesh, int iterations, {Set<int>? movable}) {
    final topo = MeshTopology(mesh);
    final boundary = <int>{};
    for (final e in topo.boundaryEdges()) {
      boundary.add(e[0]);
      boundary.add(e[1]);
    }
    final candidates = movable ??
        <int>{
          for (var v = 0; v < mesh.vertexCount; v++)
            if (!boundary.contains(v)) v,
        };
    final movableVertices =
        candidates.where((v) => !boundary.contains(v)).toList();
    for (var it = 0; it < iterations; it++) {
      final next = Float32List.fromList(mesh.positions);
      for (final v in movableVertices) {
        final nb = topo.neighborsOfVertex(v);
        if (nb.isEmpty) continue;
        var sx = 0.0, sy = 0.0, sz = 0.0;
        for (final w in nb) {
          sx += mesh.vx(w);
          sy += mesh.vy(w);
          sz += mesh.vz(w);
        }
        final k = nb.length;
        next[v * 3] = 0.5 * mesh.vx(v) + 0.5 * sx / k;
        next[v * 3 + 1] = 0.5 * mesh.vy(v) + 0.5 * sy / k;
        next[v * 3 + 2] = 0.5 * mesh.vz(v) + 0.5 * sz / k;
      }
      mesh.positions = next;
    }
  }
}
