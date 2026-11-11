import 'dart:math' as math;
import 'dart:typed_data';
import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../remesh/isotropic.dart';
import '../repair/bridge.dart';
import '../repair/weld.dart';
import '../spatial/bvh.dart';
import 'solidifier.dart';

class BooleanResult {
  final TriMesh mesh;
  final bool usedFallback;
  final String? fallbackReason;

  const BooleanResult(this.mesh,
      {this.usedFallback = false, this.fallbackReason});
}

/// Mesh-level boolean composition: classify triangles by containment, keep the
/// requested side of each input, then stitch the resulting boundary loops.
///
/// This is the remesh-and-stitch family Meshmixer describes for its Precise
/// boolean, as opposed to [Solidifier.boolean], which performs grid CSG. It
/// falls back to the grid implementation when stitching cannot close the
/// result.
class PreciseBoolean {
  static TriMesh compute(
    TriMesh a,
    TriMesh b,
    BooleanOp op, {
    double? edgeLength,
    int resolution = 160,
  }) {
    return computeDetailed(a, b, op,
            edgeLength: edgeLength, resolution: resolution)
        .mesh;
  }

  static BooleanResult computeDetailed(
    TriMesh a,
    TriMesh b,
    BooleanOp op, {
    double? edgeLength,
    int resolution = 160,
  }) {
    a.requireUntextured('Precise boolean');
    b.requireUntextured('Precise boolean');
    if (resolution < 8 ||
        resolution > 256 ||
        (edgeLength != null && (!edgeLength.isFinite || edgeLength <= 0))) {
      throw ArgumentError('Invalid boolean resolution or edge length');
    }
    final exact = trivialBoolean(a, b, op);
    if (exact != null) return BooleanResult(exact);
    var left = a;
    var right = b;
    if (edgeLength != null && edgeLength > 0) {
      left = _remesh(left, edgeLength);
      right = _remesh(right, edgeLength);
    }

    final scale = math.max(a.bounds().diagonal, b.bounds().diagonal);
    final tolerance = math.max(scale * 1e-8, 1e-30);
    final bvhLeft = TriangleBVH.build(left);
    final bvhRight = TriangleBVH.build(right);

    final builder = MeshBuilder();
    final groups = <int>[];
    final colors =
        a.vertexColors == null && b.vertexColors == null ? null : <double>[];
    void addFace(TriMesh m, int f, {bool flip = false}) {
      final i0 = m.indices[f * 3];
      final i1 = m.indices[f * 3 + 1];
      final i2 = m.indices[f * 3 + 2];
      final v0 = builder.addVertex(m.vx(i0), m.vy(i0), m.vz(i0));
      final v1 = builder.addVertex(m.vx(i1), m.vy(i1), m.vz(i1));
      final v2 = builder.addVertex(m.vx(i2), m.vy(i2), m.vz(i2));
      if (colors != null) {
        for (final v in [i0, i1, i2]) {
          colors.addAll(m.vertexColors?.sublist(v * 3, v * 3 + 3) ?? [1, 1, 1]);
        }
      }
      if (flip) {
        builder.addTriangle(v0, v2, v1);
      } else {
        builder.addTriangle(v0, v1, v2);
      }
      groups.add(m.faceGroups == null ? 0 : m.faceGroups![f]);
    }

    final keepLeftInside = op == BooleanOp.intersection;
    final keepRightInside = op != BooleanOp.union;

    for (var f = 0; f < left.faceCount; f++) {
      final inside = _inside(bvhRight, left, f, tolerance);
      if (inside == keepLeftInside) addFace(left, f);
    }
    for (var f = 0; f < right.faceCount; f++) {
      final inside = _inside(bvhLeft, right, f, tolerance);
      if (inside == keepRightInside) {
        addFace(right, f, flip: op == BooleanOp.difference);
      }
    }

    var out = builder.build()
      ..faceGroups = a.faceGroups == null && b.faceGroups == null
          ? null
          : Uint16List.fromList(groups)
      ..vertexColors = colors == null ? null : Float32List.fromList(colors);
    if (out.faceCount == 0) {
      return BooleanResult(
        Solidifier.boolean(a, b, op, resolution: resolution).mesh,
        usedFallback: true,
        fallbackReason: 'empty mesh-level result',
      );
    }
    out = Weld.weldVertices(out, tolerance: tolerance);
    try {
      out = Bridge.stitchNearest(out,
          maxGap: out.bounds().diagonal * 0.25, maxPairs: 64);
    } on StateError catch (error) {
      return BooleanResult(
          Solidifier.boolean(a, b, op, resolution: resolution).mesh,
          usedFallback: true,
          fallbackReason: 'invalid bridge: ${error.message}');
    } on ArgumentError catch (error) {
      return BooleanResult(
          Solidifier.boolean(a, b, op, resolution: resolution).mesh,
          usedFallback: true,
          fallbackReason: 'unsupported bridge: ${error.message}');
    }
    out = Weld.weldCracks(out, tolerance: tolerance);
    out.removeDegenerateFaces(minArea: scale * scale * 1e-16);
    out.compact();

    final topology = MeshTopology(out);
    String? rejection;
    if (topology.boundaryLoops().isNotEmpty) {
      rejection = 'stitching left boundary loops';
    } else if (topology.nonManifoldEdges().isNotEmpty) {
      rejection = 'stitching produced non-manifold edges';
    } else if (!_consistentWinding(out, topology)) {
      rejection = 'stitching produced inconsistent winding';
    } else if (out.signedVolume() <= scale * scale * scale * 1e-12) {
      rejection = 'zero-volume or inverted result';
    }
    if (rejection != null) {
      return BooleanResult(
        Solidifier.boolean(a, b, op, resolution: resolution).mesh,
        usedFallback: true,
        fallbackReason: rejection,
      );
    }
    return BooleanResult(out);
  }

  static bool _consistentWinding(TriMesh mesh, MeshTopology topology) {
    for (final entry in topology.edgeFaces.entries) {
      final a = entry.key ~/ mesh.vertexCount;
      final b = entry.key % mesh.vertexCount;
      var orientation = 0;
      for (final face in entry.value) {
        for (var k = 0; k < 3; k++) {
          final from = mesh.indices[face * 3 + k];
          final to = mesh.indices[face * 3 + (k + 1) % 3];
          if (from == a && to == b) orientation++;
          if (from == b && to == a) orientation--;
        }
      }
      if (orientation != 0) return false;
    }
    return true;
  }

  static TriMesh _remesh(TriMesh mesh, double edgeLength) {
    return IsotropicRemesher.remesh(
      mesh,
      targetEdgeLength: edgeLength,
      iterations: 3,
      preserveBoundary: false,
    );
  }

  static bool _inside(
      TriangleBVH bvh, TriMesh mesh, int face, double tolerance) {
    final a = mesh.indices[face * 3];
    final b = mesh.indices[face * 3 + 1];
    final c = mesh.indices[face * 3 + 2];
    final x = (mesh.vx(a) + mesh.vx(b) + mesh.vx(c)) / 3.0;
    final y = (mesh.vy(a) + mesh.vy(b) + mesh.vy(c)) / 3.0;
    final z = (mesh.vz(a) + mesh.vz(b) + mesh.vz(c)) / 3.0;
    const inv = 0.5773502691896258;
    final hits = bvh.raycastAll(<double>[x, y, z], <double>[inv, inv, inv]);
    var crossings = 0;
    double? previous;
    for (final t in hits) {
      if (previous == null || (t - previous).abs() > tolerance) {
        crossings++;
        previous = t;
      }
    }
    return crossings.isOdd;
  }
}
