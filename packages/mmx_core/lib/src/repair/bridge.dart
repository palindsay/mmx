import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';

/// Bridges pairs of open boundary loops, the job Meshmixer's
/// BoundaryBridge/BoundaryJoiner tools do. The strip is built by walking both
/// loops from their closest pair and advancing whichever side keeps the
/// triangles well shaped, so both loops are consumed completely.
class Bridge {
  /// Connects two ordered boundary loops. Returns the input unchanged when a
  /// loop has fewer than three vertices.
  static TriMesh bridgeLoops(TriMesh mesh, List<int> loopA, List<int> loopB) {
    mesh.requireUntextured('Bridge');
    if (loopA.length < 3 || loopB.length < 3) return mesh.clone();

    if (loopA.length * loopB.length > 5000000 ||
        {...loopA, ...loopB}.length != loopA.length + loopB.length ||
        [...loopA, ...loopB].any((v) => v < 0 || v >= mesh.vertexCount)) {
      throw ArgumentError(
          'Bridge requires disjoint simple loops within its comparison budget');
    }
    final topo = MeshTopology(mesh);
    int direction(int a, int b) {
      final faces = topo.edgeFaces[topo.edgeKey(a, b)];
      if (faces == null || faces.length != 1) {
        throw ArgumentError('Bridge loops must follow open boundary edges');
      }
      final f = faces.single;
      for (var k = 0; k < 3; k++) {
        if (mesh.indices[f * 3 + k] == a &&
            mesh.indices[f * 3 + (k + 1) % 3] == b) {
          return 1;
        }
      }
      return -1;
    }

    List<int> orient(List<int> loop, int wanted) {
      final forward = direction(loop[0], loop[1]);
      for (var i = 1; i < loop.length; i++) {
        if (direction(loop[i], loop[(i + 1) % loop.length]) != forward) {
          throw StateError(
              'Repair inconsistent boundary winding before bridging');
        }
      }
      return forward == wanted ? List<int>.from(loop) : loop.reversed.toList();
    }

    // Existing A edges run forward; B runs backward. The new strip reverses
    // every existing boundary edge and uses opposite directions internally.
    var a = orient(loopA, 1), b = orient(loopB, -1);
    var bestA = 0, bestB = 0, bestD = double.infinity;
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < b.length; j++) {
        final distance = _dist(mesh, a[i], b[j]);
        if (distance < bestD) {
          bestD = distance;
          bestA = i;
          bestB = j;
        }
      }
    }
    a = [for (var k = 0; k < a.length; k++) a[(bestA + k) % a.length]];
    b = [for (var k = 0; k < b.length; k++) b[(bestB + k) % b.length]];
    final indices = <int>[...mesh.indices];
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      final av = a[i % a.length], bv = b[j % b.length];
      final an = a[(i + 1) % a.length], bn = b[(j + 1) % b.length];
      final da = _dist(mesh, an, bv), db = _dist(mesh, av, bn);
      // Compare proposed diagonals. Do not close one ring while the other has
      // not advanced: that creates a pinched fan with a non-manifold seam.
      final advanceA = j == b.length ||
          (i < a.length &&
              !(i == a.length - 1 && j == 0) &&
              ((j == b.length - 1 && i == 0) ||
                  da < db ||
                  (da == db && i / a.length <= j / b.length)));
      if (advanceA) {
        indices.addAll([av, bv, an]);
        i++;
      } else {
        indices.addAll([av, bv, bn]);
        j++;
      }
    }
    final out = mesh.clone()..indices = Uint32List.fromList(indices);
    if (mesh.faceGroups != null) {
      out.faceGroups = Uint16List.fromList(
          [...mesh.faceGroups!, ...List<int>.filled(a.length + b.length, 0)]);
    }
    for (var f = mesh.faceCount; f < out.faceCount; f++) {
      final a = out.indices[f * 3],
          b = out.indices[f * 3 + 1],
          c = out.indices[f * 3 + 2];
      final ux = out.vx(b) - out.vx(a),
          uy = out.vy(b) - out.vy(a),
          uz = out.vz(b) - out.vz(a);
      final vx = out.vx(c) - out.vx(a),
          vy = out.vy(c) - out.vy(a),
          vz = out.vz(c) - out.vz(a);
      final x = uy * vz - uz * vy, y = uz * vx - ux * vz, z = ux * vy - uy * vx;
      if (x * x + y * y + z * z == 0) {
        throw StateError('Bridge would create a degenerate triangle');
      }
    }
    final after = MeshTopology(out);
    for (final loop in [a, b]) {
      for (var k = 0; k < loop.length; k++) {
        if (after.edgeFaces[after.edgeKey(loop[k], loop[(k + 1) % loop.length])]
                ?.length !=
            2) {
          throw StateError('Bridge did not close the requested boundary');
        }
      }
    }
    return out;
  }

  /// Pairs boundary loops by centroid proximity and bridges them, largest gap
  /// first limited by [maxGap]. Use this to stitch a slit or join two halves.
  static TriMesh stitchNearest(TriMesh mesh,
      {double? maxGap, int maxPairs = 8}) {
    var work = mesh.clone();
    final gap = maxGap ?? work.bounds().diagonal * 0.2;
    var pairs = 0;
    while (pairs < maxPairs) {
      final loops = MeshTopology(work).boundaryLoops();
      if (loops.length < 2) break;
      var bi = -1, bj = -1;
      var bestD = double.infinity;
      for (var i = 0; i < loops.length; i++) {
        for (var j = i + 1; j < loops.length; j++) {
          final d = _centroidDistance(work, loops[i], loops[j]);
          if (d < bestD) {
            bestD = d;
            bi = i;
            bj = j;
          }
        }
      }
      if (bi < 0 || bestD > gap) break;
      final next = bridgeLoops(work, loops[bi], loops[bj]);
      if (MeshTopology(next).boundaryLoops().length >= loops.length) break;
      work = next;
      pairs++;
    }
    return work;
  }

  static double _centroidDistance(TriMesh mesh, List<int> a, List<int> b) {
    var ax = 0.0, ay = 0.0, az = 0.0;
    for (final v in a) {
      ax += mesh.vx(v);
      ay += mesh.vy(v);
      az += mesh.vz(v);
    }
    ax /= a.length;
    ay /= a.length;
    az /= a.length;
    var bx = 0.0, by = 0.0, bz = 0.0;
    for (final v in b) {
      bx += mesh.vx(v);
      by += mesh.vy(v);
      bz += mesh.vz(v);
    }
    bx /= b.length;
    by /= b.length;
    bz /= b.length;
    return math.sqrt(
        math.pow(ax - bx, 2) + math.pow(ay - by, 2) + math.pow(az - bz, 2));
  }

  static double _dist(TriMesh mesh, int a, int b) {
    final dx = mesh.vx(a) - mesh.vx(b);
    final dy = mesh.vy(a) - mesh.vy(b);
    final dz = mesh.vz(a) - mesh.vz(b);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }
}
