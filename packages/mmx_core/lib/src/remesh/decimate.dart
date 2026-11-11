import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/attributes.dart';
import '../mesh/tri_mesh.dart';

/// Quadric-error-metric decimation.
///
/// The shipped binary exposes ReduceTool.cpp / MeshReducer.cpp with
/// "Reduce Type: Percentage | Triangle Budget | Max Deviation" and
/// "Preserve Boundaries / Preserve Group Boundaries". This implementation
/// accumulates per-vertex quadrics from incident face planes (plus boundary
/// constraint planes), and collapses the cheapest legal edge until the target
/// face budget is met.
class Decimator {
  static TriMesh reduce(
    TriMesh input, {
    int? targetFaceCount,
    double? percentage,
    bool preserveBoundary = true,
    bool uniform = false,
    double? maxDeviation,
    void Function(int current, int target)? progress,
  }) {
    input.requireUntextured('Decimation');
    if ((percentage != null &&
            (!percentage.isFinite || percentage < 0 || percentage > 1)) ||
        (targetFaceCount != null && targetFaceCount < 0) ||
        (maxDeviation != null &&
            (!maxDeviation.isFinite || maxDeviation < 0))) {
      throw ArgumentError('Invalid reduction target or deviation');
    }
    final target = targetFaceCount ??
        (percentage == null
            ? (input.faceCount * 0.5).round()
            : (input.faceCount * percentage).round());
    if (target >= input.faceCount || input.faceCount == 0) return input.clone();

    final pinned = preserveBoundary
        ? {for (final e in MeshTopology(input).boundaryEdges()) ...e.take(2)}
        : <int>{};
    final n = input.vertexCount;
    final positions = <double>[...input.positions];
    final faces = <List<int>>[];
    for (var f = 0; f < input.faceCount; f++) {
      faces.add(<int>[
        input.indices[f * 3],
        input.indices[f * 3 + 1],
        input.indices[f * 3 + 2],
      ]);
    }
    final faceAlive = List<bool>.filled(faces.length, true);
    final vAlive = List<bool>.filled(n, true);
    final revisions = Uint32List(n);
    final vFaces = List<Set<int>>.generate(n, (_) => <int>{});
    for (var f = 0; f < faces.length; f++) {
      for (final v in faces[f]) {
        vFaces[v].add(f);
      }
    }

    final quadrics = List<Float64List>.generate(n, (_) => Float64List(10));
    for (var f = 0; f < faces.length; f++) {
      _accumulatePlane(quadrics, positions, faces[f]);
    }
    if (preserveBoundary) {
      final topo = MeshTopology(input);
      for (final e in topo.boundaryEdges()) {
        final a = e[0], b = e[1];
        // Constraint plane through the edge, perpendicular to the surface.
        final ax = positions[a * 3],
            ay = positions[a * 3 + 1],
            az = positions[a * 3 + 2];
        final bx = positions[b * 3],
            by = positions[b * 3 + 1],
            bz = positions[b * 3 + 2];
        final ex = bx - ax, ey = by - ay, ez = bz - az;
        // Approximate surface normal from an incident face.
        var nx = 0.0, ny = 0.0, nz = 0.0;
        for (final f in vFaces[a]) {
          final nrm = _faceNormal(positions, faces[f]);
          nx += nrm[0];
          ny += nrm[1];
          nz += nrm[2];
        }
        var px = ey * nz - ez * ny,
            py = ez * nx - ex * nz,
            pz = ex * ny - ey * nx;
        final l = math.sqrt(px * px + py * py + pz * pz);
        if (l < 1e-20) continue;
        px /= l;
        py /= l;
        pz /= l;
        final d = -(px * ax + py * ay + pz * az);
        _addPlane(quadrics[a], px, py, pz, d, 10.0);
        _addPlane(quadrics[b], px, py, pz, d, 10.0);
      }
    }

    var liveFaces = faces.length;
    final heap = _EdgeHeap();
    void pushEdges(int v) {
      for (final w in _neighbors(vFaces[v], faces)) {
        if (!vAlive[w] || w == v || pinned.contains(v) || pinned.contains(w)) {
          continue;
        }
        if (uniform) {
          // Meshmixer's Uniform reduce uses a shortest-edges-first criterion
          // and collapses to the midpoint, producing regularly shaped
          // triangles rather than preserving the shape.
          final dx = positions[v * 3] - positions[w * 3];
          final dy = positions[v * 3 + 1] - positions[w * 3 + 1];
          final dz = positions[v * 3 + 2] - positions[w * 3 + 2];
          final len = math.sqrt(dx * dx + dy * dy + dz * dz);
          heap.push(
              len,
              v,
              w,
              (positions[v * 3] + positions[w * 3]) * 0.5,
              (positions[v * 3 + 1] + positions[w * 3 + 1]) * 0.5,
              (positions[v * 3 + 2] + positions[w * 3 + 2]) * 0.5,
              revisions[v],
              revisions[w]);
          continue;
        }
        final cost = _collapseCost(quadrics[v], quadrics[w], positions, v, w);
        heap.push(cost.cost, v, w, cost.x, cost.y, cost.z, revisions[v],
            revisions[w]);
      }
    }

    for (var v = 0; v < n; v++) {
      pushEdges(v);
    }

    var guard = 0;
    final destination = Float32List(3);
    while (liveFaces > target && heap.isNotEmpty) {
      final e = heap.pop();
      final a = e.a, b = e.b;
      if (!vAlive[a] || !vAlive[b]) continue;
      // An earlier collapse changes both the endpoint quadric and its position.
      // Reject stale queue entries before using their cost or destination.
      if (e.revisionA != revisions[a] || e.revisionB != revisions[b]) continue;
      if (!_isEdge(vFaces[a], vFaces[b], faces)) continue;
      if (maxDeviation != null && e.cost > maxDeviation * maxDeviation) break;
      // Geometry is stored as float32. Check the actual representable point:
      // validating a float64 optimum can accept distinct vertices that become
      // coincident only when the final output buffer is constructed.
      destination[0] = e.x;
      destination[1] = e.y;
      destination[2] = e.z;
      final x = destination[0], y = destination[1], z = destination[2];
      if (!x.isFinite || !y.isFinite || !z.isFinite) continue;
      if (!_legalCollapse(vFaces, faces, vAlive, a, b, positions, x, y, z)) {
        continue;
      }
      // Move b to the optimal position, kill a.
      positions[b * 3] = x;
      positions[b * 3 + 1] = y;
      positions[b * 3 + 2] = z;
      revisions[b]++;
      guard++;
      for (var k = 0; k < 10; k++) {
        quadrics[b][k] += quadrics[a][k];
      }
      for (final f in vFaces[a].toList()) {
        if (!faceAlive[f]) continue;
        final tri = faces[f];
        final idx = tri.indexOf(a);
        if (idx < 0) continue;
        if (tri.contains(b)) {
          faceAlive[f] = false;
          liveFaces--;
          for (final v in tri) {
            vFaces[v].remove(f);
          }
          continue;
        }
        tri[idx] = b;
        vFaces[b].add(f);
      }
      vFaces[a].clear();
      vAlive[a] = false;
      pushEdges(b);
      if (progress != null && guard % 512 == 0) progress(liveFaces, target);
    }
    progress?.call(liveFaces, target);

    final builder = MeshBuilder();
    final groups = input.faceGroups == null ? null : <int>[];
    final remap = Int32List(n);
    for (var v = 0; v < n; v++) {
      remap[v] = -1;
    }
    for (var f = 0; f < faces.length; f++) {
      if (!faceAlive[f]) continue;
      final tri = faces[f];
      final ids = <int>[];
      for (final v in tri) {
        if (remap[v] < 0) {
          remap[v] = builder.addVertex(
              positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
        }
        ids.add(remap[v]);
      }
      if (ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2]) continue;
      builder.addTriangle(ids[0], ids[1], ids[2]);
      groups?.add(input.faceGroups![f]);
    }
    final out = builder.build()
      ..faceGroups = groups == null ? null : Uint16List.fromList(groups);
    // Every accepted destination was validated at output precision. Deleting
    // surviving faces here would silently open a previously closed surface.
    out.compact();
    out.vertexColors = transferVertexColors(input, out);
    return out;
  }

  static Set<int> _neighbors(Set<int> vfaces, List<List<int>> faces) {
    final out = <int>{};
    for (final f in vfaces) {
      for (final v in faces[f]) {
        out.add(v);
      }
    }
    return out;
  }

  static bool _isEdge(Set<int> fa, Set<int> fb, List<List<int>> faces) {
    for (final f in fa) {
      if (fb.contains(f)) return true;
    }
    return false;
  }

  /// Link condition plus a degenerate/zero-area rejection for the moved faces.
  static bool _legalCollapse(
      List<Set<int>> vFaces,
      List<List<int>> faces,
      List<bool> vAlive,
      int a,
      int b,
      List<double> positions,
      double tx,
      double ty,
      double tz) {
    final na = _neighbors(vFaces[a], faces);
    final nb = _neighbors(vFaces[b], faces);
    na.remove(a);
    nb.remove(b);
    final common = na.intersection(nb);
    final opposite = <int>{};
    var sharedFaces = 0;
    for (final face in vFaces[a]) {
      if (!vFaces[b].contains(face)) continue;
      sharedFaces++;
      for (final vertex in faces[face]) {
        if (vertex != a && vertex != b) opposite.add(vertex);
      }
    }
    // The edge link must equal the intersection of its endpoint links, not
    // merely contain at most two vertices. Otherwise collapsing the edge can
    // identify unrelated surface fans or duplicate an existing triangle.
    if (sharedFaces < 1 ||
        sharedFaces > 2 ||
        opposite.length != sharedFaces ||
        common.length != opposite.length ||
        !common.containsAll(opposite)) {
      return false;
    }
    if (na.length + nb.length - 2 * common.length < 3) return false;
    for (final f in vFaces[a]) {
      final tri = faces[f];
      if (tri.contains(b)) continue;
      if (!_nonDegenerate(positions, tri, a, tx, ty, tz)) return false;
    }
    for (final f in vFaces[b]) {
      final tri = faces[f];
      if (tri.contains(a)) continue;
      if (!_nonDegenerate(positions, tri, b, tx, ty, tz)) return false;
    }
    return true;
  }

  /// Checks that the triangle stays non-degenerate after vertex [move] is
  /// relocated to (tx,ty,tz).
  static bool _nonDegenerate(List<double> positions, List<int> tri, int move,
      double tx, double ty, double tz) {
    final p = <List<double>>[];
    for (final v in tri) {
      if (v == move) {
        p.add(<double>[tx, ty, tz]);
      } else {
        p.add(<double>[
          positions[v * 3],
          positions[v * 3 + 1],
          positions[v * 3 + 2]
        ]);
      }
    }
    final ux = p[1][0] - p[0][0],
        uy = p[1][1] - p[0][1],
        uz = p[1][2] - p[0][2];
    final wx = p[2][0] - p[0][0],
        wy = p[2][1] - p[0][1],
        wz = p[2][2] - p[0][2];
    final nx = uy * wz - uz * wy,
        ny = uz * wx - ux * wz,
        nz = ux * wy - uy * wx;
    if (nx * nx + ny * ny + nz * nz <= 1e-18) return false;
    final ax = positions[tri[0] * 3],
        ay = positions[tri[0] * 3 + 1],
        az = positions[tri[0] * 3 + 2];
    final ux0 = positions[tri[1] * 3] - ax,
        uy0 = positions[tri[1] * 3 + 1] - ay,
        uz0 = positions[tri[1] * 3 + 2] - az;
    final wx0 = positions[tri[2] * 3] - ax,
        wy0 = positions[tri[2] * 3 + 1] - ay,
        wz0 = positions[tri[2] * 3 + 2] - az;
    final beforeX = uy0 * wz0 - uz0 * wy0;
    final beforeY = uz0 * wx0 - ux0 * wz0;
    final beforeZ = ux0 * wy0 - uy0 * wx0;
    return nx * beforeX + ny * beforeY + nz * beforeZ > 0;
  }

  static List<double> _faceNormal(List<double> positions, List<int> tri) {
    final ax = positions[tri[0] * 3],
        ay = positions[tri[0] * 3 + 1],
        az = positions[tri[0] * 3 + 2];
    final bx = positions[tri[1] * 3],
        by = positions[tri[1] * 3 + 1],
        bz = positions[tri[1] * 3 + 2];
    final cx = positions[tri[2] * 3],
        cy = positions[tri[2] * 3 + 1],
        cz = positions[tri[2] * 3 + 2];
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final wx = cx - ax, wy = cy - ay, wz = cz - az;
    var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-20) return <double>[0, 0, 1];
    return <double>[nx / l, ny / l, nz / l];
  }

  static void _accumulatePlane(
      List<Float64List> quadrics, List<double> positions, List<int> tri) {
    final nrm = _faceNormal(positions, tri);
    final ax = positions[tri[0] * 3],
        ay = positions[tri[0] * 3 + 1],
        az = positions[tri[0] * 3 + 2];
    final bx = positions[tri[1] * 3],
        by = positions[tri[1] * 3 + 1],
        bz = positions[tri[1] * 3 + 2];
    final cx = positions[tri[2] * 3],
        cy = positions[tri[2] * 3 + 1],
        cz = positions[tri[2] * 3 + 2];
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    final crx = uy * vz - uz * vy;
    final cry = uz * vx - ux * vz;
    final crz = ux * vy - uy * vx;
    final area = 0.5 * math.sqrt(crx * crx + cry * cry + crz * crz);
    final d = -(nrm[0] * ax + nrm[1] * ay + nrm[2] * az);
    // geometry3Sharp weights vertex quadrics by incident triangle area; doing
    // the same makes collapse order scale with surface area rather than with
    // triangle count.
    final w = area > 1e-12 ? area : 1e-12;
    for (final v in tri) {
      _addPlane(quadrics[v], nrm[0], nrm[1], nrm[2], d, w);
    }
  }

  /// Adds w * [n,d]^T[n,d] to a symmetric 10-element quadric.
  static void _addPlane(
      Float64List q, double nx, double ny, double nz, double d, double w) {
    q[0] += w * nx * nx;
    q[1] += w * nx * ny;
    q[2] += w * nx * nz;
    q[3] += w * nx * d;
    q[4] += w * ny * ny;
    q[5] += w * ny * nz;
    q[6] += w * ny * d;
    q[7] += w * nz * nz;
    q[8] += w * nz * d;
    q[9] += w * d * d;
  }

  static _Cost _collapseCost(
      Float64List qa, Float64List qb, List<double> positions, int a, int b) {
    final q = Float64List(10);
    for (var i = 0; i < 10; i++) {
      q[i] = qa[i] + qb[i];
    }
    // Solve for the optimal position; a singular quadric is common on planar
    // surfaces. Choose the best endpoint/midpoint instead of moving corners
    // off their constraint planes merely because the system is singular.
    final m11 = q[0], m12 = q[1], m13 = q[2];
    final m22 = q[4], m23 = q[5], m33 = q[7];
    final r1 = -q[3], r2 = -q[6], r3 = -q[8];
    final det = m11 * (m22 * m33 - m23 * m23) -
        m12 * (m12 * m33 - m23 * m13) +
        m13 * (m12 * m23 - m22 * m13);
    double x, y, z;
    if (det.abs() > 1e-18) {
      x = (r1 * (m22 * m33 - m23 * m23) -
              m12 * (r2 * m33 - m23 * r3) +
              m13 * (r2 * m23 - m22 * r3)) /
          det;
      y = (m11 * (r2 * m33 - r3 * m23) -
              r1 * (m12 * m33 - m23 * m13) +
              m13 * (m12 * r3 - r2 * m13)) /
          det;
      z = (m11 * (m22 * r3 - r2 * m23) -
              m12 * (m12 * r3 - r2 * m13) +
              r1 * (m12 * m23 - m22 * m13)) /
          det;
    } else {
      x = (positions[a * 3] + positions[b * 3]) * 0.5;
      y = (positions[a * 3 + 1] + positions[b * 3 + 1]) * 0.5;
      z = (positions[a * 3 + 2] + positions[b * 3 + 2]) * 0.5;
      var best = _quadricError(q, x, y, z);
      for (final v in [a, b]) {
        final error = _quadricError(
            q, positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
        if (error < best) {
          best = error;
          x = positions[v * 3];
          y = positions[v * 3 + 1];
          z = positions[v * 3 + 2];
        }
      }
    }
    final err = _quadricError(q, x, y, z);
    // Bias toward short edges so we do not skip small features early.
    final dx = positions[a * 3] - positions[b * 3];
    final dy = positions[a * 3 + 1] - positions[b * 3 + 1];
    final dz = positions[a * 3 + 2] - positions[b * 3 + 2];
    final len = math.sqrt(dx * dx + dy * dy + dz * dz);
    return _Cost(err + 1e-6 * len, x, y, z);
  }

  static double _quadricError(Float64List q, double x, double y, double z) {
    return q[0] * x * x +
        2 * q[1] * x * y +
        2 * q[2] * x * z +
        2 * q[3] * x +
        q[4] * y * y +
        2 * q[5] * y * z +
        2 * q[6] * y +
        q[7] * z * z +
        2 * q[8] * z +
        q[9];
  }
}

class _Cost {
  final double cost;
  final double x, y, z;
  _Cost(this.cost, this.x, this.y, this.z);
}

class _Edge {
  final double cost;
  final int a, b;
  final double x, y, z;
  final int revisionA, revisionB;
  _Edge(this.cost, this.a, this.b, this.x, this.y, this.z, this.revisionA,
      this.revisionB);
}

/// Binary min-heap over edges.
class _EdgeHeap {
  final List<_Edge> _items = <_Edge>[];

  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;

  void push(double cost, int a, int b, double x, double y, double z,
      int revisionA, int revisionB) {
    _items.add(_Edge(cost, a, b, x, y, z, revisionA, revisionB));
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_items[parent].cost <= _items[i].cost) break;
      final t = _items[parent];
      _items[parent] = _items[i];
      _items[i] = t;
      i = parent;
    }
  }

  _Edge pop() {
    final top = _items.first;
    final last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = 2 * i + 2;
        var smallest = i;
        if (l < _items.length && _items[l].cost < _items[smallest].cost) {
          smallest = l;
        }
        if (r < _items.length && _items[r].cost < _items[smallest].cost) {
          smallest = r;
        }
        if (smallest == i) break;
        final t = _items[smallest];
        _items[smallest] = _items[i];
        _items[i] = t;
        i = smallest;
      }
    }
    return top;
  }
}
