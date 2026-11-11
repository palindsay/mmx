import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/attributes.dart';
import '../mesh/limits.dart';
import '../mesh/tri_mesh.dart';
import '../repair/weld.dart';
import '../spatial/bvh.dart';
import 'collapse_mesh.dart';

class RemeshResult {
  final TriMesh mesh;
  final bool usedUniformFallback;
  final String? fallbackReason;

  const RemeshResult(this.mesh,
      {this.usedUniformFallback = false, this.fallbackReason});
}

/// Isotropic remeshing in the Botsch-Kobbelt style: split long edges, collapse
/// short ones, flip toward valence six, then relax tangentially and project
/// back onto the input surface.
///
/// This stands in for Meshmixer's SurfaceRemesher.cpp / VariationalRemesher.cpp
/// (the tool panel exposes "Remesh Mode / Remesh Type / Target Edge Length /
/// Regularity / Adaptive Density / Preserve Sharp Edges / Boundary Mode").
class IsotropicRemesher {
  /// Linear subdivision: splits every triangle into four by adding edge
  /// midpoints. This exactly preserves the input surface, matching Meshmixer's
  /// Linear Subdivision remesh mode. Face groups are inherited by the children.
  static TriMesh linearSubdivide(TriMesh input,
      {int maximumFaces = defaultMaximumGeneratedFaces}) {
    final faces =
        checkedFaceProduct(input.faceCount, 4, maximumFaces, 'Subdivision');
    checkGeneratedSize(faces, input.vertexCount + input.indices.length,
        maximumFaces, 'Subdivision');
    final positions = <double>[...input.positions];
    final indices = <int>[];
    final groups = input.faceGroups == null ? null : <int>[];
    final uvs = input.cornerUvs == null ? null : <double>[];
    final materialIds = input.faceMaterials == null ? null : <int>[];
    final colors =
        input.vertexColors == null ? null : <double>[...input.vertexColors!];
    final mids = <String, int>{};
    int mid(int a, int b) {
      final key = a < b ? '$a:$b' : '$b:$a';
      final existing = mids[key];
      if (existing != null) return existing;
      final idx = positions.length ~/ 3;
      positions.add((input.vx(a) + input.vx(b)) * 0.5);
      positions.add((input.vy(a) + input.vy(b)) * 0.5);
      positions.add((input.vz(a) + input.vz(b)) * 0.5);
      if (colors != null) {
        for (var k = 0; k < 3; k++) {
          colors.add((input.vertexColors![a * 3 + k] +
                  input.vertexColors![b * 3 + k]) *
              .5);
        }
      }
      mids[key] = idx;
      return idx;
    }

    for (var f = 0; f < input.faceCount; f++) {
      final a = input.indices[f * 3];
      final b = input.indices[f * 3 + 1];
      final c = input.indices[f * 3 + 2];
      final ab = mid(a, b);
      final bc = mid(b, c);
      final ca = mid(c, a);
      indices.addAll([a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca]);
      if (uvs != null) {
        final corners = [
          for (var k = 0; k < 3; k++)
            [
              input.cornerUvs![f * 6 + k * 2],
              input.cornerUvs![f * 6 + k * 2 + 1]
            ]
        ];
        final mids = [
          for (var k = 0; k < 3; k++)
            [
              for (var c = 0; c < 2; c++)
                (corners[k][c] + corners[(k + 1) % 3][c]) * .5
            ]
        ];
        for (final uv in [
          corners[0],
          mids[0],
          mids[2],
          mids[0],
          corners[1],
          mids[1],
          mids[2],
          mids[1],
          corners[2],
          mids[0],
          mids[1],
          mids[2]
        ]) {
          uvs.addAll(uv);
        }
      }
      if (materialIds != null) {
        materialIds.addAll(List.filled(4, input.faceMaterials![f]));
      }
      if (groups != null) {
        final g = input.faceGroups![f];
        groups.addAll([g, g, g, g]);
      }
    }
    return TriMesh(
      Float32List.fromList(positions),
      Uint32List.fromList(indices),
      faceGroups: groups == null ? null : Uint16List.fromList(groups),
      vertexColors: colors == null ? null : Float32List.fromList(colors),
      cornerUvs: uvs == null ? null : Float32List.fromList(uvs),
      faceMaterials:
          materialIds == null ? null : Uint16List.fromList(materialIds),
      materials: input.materials,
    );
  }

  /// [targetEdgeLength] is in mesh units. [iterations] controls quality vs
  /// speed. [preserveBoundary] pins open boundaries, matching the
  /// "Preserve Mesh Boundary" parameter in the shipped tool.
  ///
  /// [preserveGroupBoundaries] implements the VariationalRemesher behaviour the
  /// first pass left out: edges between different face groups act as internal
  /// sharp constraints, and the group assignment is carried onto the output
  /// mesh by nearest-surface lookup. Constraint vertices are recomputed from
  /// the live mesh every iteration, because split/collapse renumber vertices.
  static TriMesh remesh(
    TriMesh input, {
    required double targetEdgeLength,
    int iterations = 6,
    bool preserveBoundary = true,
    bool preserveSharp = false,
    double sharpAngleDegrees = 45,
    bool preserveGroupBoundaries = false,
    double adaptiveDensity = 0.0,
    bool debugTopology = false,
    void Function(int done, int total)? progress,
    int maximumFaces = defaultMaximumGeneratedFaces,
  }) {
    return remeshDetailed(
      input,
      targetEdgeLength: targetEdgeLength,
      iterations: iterations,
      preserveBoundary: preserveBoundary,
      preserveSharp: preserveSharp,
      sharpAngleDegrees: sharpAngleDegrees,
      preserveGroupBoundaries: preserveGroupBoundaries,
      adaptiveDensity: adaptiveDensity,
      debugTopology: debugTopology,
      progress: progress,
      maximumFaces: maximumFaces,
    ).mesh;
  }

  static RemeshResult remeshDetailed(
    TriMesh input, {
    required double targetEdgeLength,
    int iterations = 6,
    bool preserveBoundary = true,
    bool preserveSharp = false,
    double sharpAngleDegrees = 45,
    bool preserveGroupBoundaries = false,
    double adaptiveDensity = 0.0,
    bool debugTopology = false,
    void Function(int done, int total)? progress,
    int maximumFaces = defaultMaximumGeneratedFaces,
  }) {
    input.requireUntextured('Isotropic remesh');
    if (!targetEdgeLength.isFinite ||
        targetEdgeLength <= 0 ||
        iterations < 0 ||
        iterations > 1000 ||
        !adaptiveDensity.isFinite ||
        adaptiveDensity < 0 ||
        adaptiveDensity > 1 ||
        !sharpAngleDegrees.isFinite ||
        sharpAngleDegrees < 0 ||
        sharpAngleDegrees > 180) {
      throw ArgumentError('Invalid remesh parameters');
    }
    checkGeneratedSize(
        input.faceCount, input.vertexCount, maximumFaces, 'Remesh');
    if (iterations > 0 &&
        input.surfaceArea() /
                (targetEdgeLength * targetEdgeLength * .4330127018922193) >
            maximumFaces) {
      throw StateError(
          'Requested remesh edge length exceeds the output face budget');
    }
    if (input.faceCount == 0) return RemeshResult(input);
    final originalBvh = TriangleBVH.build(input);
    var mesh = input.clone();
    final groupSegments = (preserveGroupBoundaries && input.faceGroups != null)
        ? _groupBoundarySegments(input)
        : const <List<double>>[];
    final groupTolerance = targetEdgeLength * 0.6;

    Set<int> constraints(TriMesh m) {
      final out = <int>{};
      if (preserveSharp) {
        out.addAll(_sharpVertices(m, sharpAngleDegrees * math.pi / 180));
      }
      if (groupSegments.isNotEmpty) {
        out.addAll(_verticesNearSegments(m, groupSegments, groupTolerance));
      }
      return out;
    }

    for (var it = 0; it < iterations; it++) {
      progress?.call(it, iterations);
      final curvSplit = adaptiveDensity > 0 ? _curvature(mesh) : null;
      double density(List<double> c, int a, int b) =>
          (1.0 + adaptiveDensity * (c[a] + c[b]) * 0.5).clamp(0.25, 4.0);

      if (debugTopology) {
        final t = MeshTopology(mesh);
        print(
            'before split nm=${t.nonManifoldEdges().length} b=${t.boundaryLoops().length}');
      }
      mesh = _splitLong(mesh, targetEdgeLength * 4.0 / 3.0,
          maximumFaces: maximumFaces,
          preserveBoundary: preserveBoundary,
          maxFor: curvSplit == null
              ? null
              : (a, b) =>
                  targetEdgeLength * 4.0 / 3.0 * density(curvSplit, a, b));
      if (debugTopology) {
        final t = MeshTopology(mesh);
        print(
            'after split nm=${t.nonManifoldEdges().length} b=${t.boundaryLoops().length}');
      }
      final curvCollapse = adaptiveDensity > 0 ? _curvature(mesh) : null;
      mesh = _collapseShort(
          mesh, targetEdgeLength * 0.8, preserveBoundary, constraints(mesh),
          minFor: curvCollapse == null
              ? null
              : (a, b) => targetEdgeLength * 0.8 * density(curvCollapse, a, b));
      if (debugTopology) {
        final t = MeshTopology(mesh);
        print(
            'after collapse nm=${t.nonManifoldEdges().length} b=${t.boundaryLoops().length}');
      }
      mesh = _flipForValence(mesh, preserveBoundary, constraints(mesh));
      if (debugTopology) {
        final t = MeshTopology(mesh);
        print(
            'after flip nm=${t.nonManifoldEdges().length} b=${t.boundaryLoops().length}');
      }
      mesh = _tangentialRelax(
          mesh, originalBvh, preserveBoundary, constraints(mesh));
      mesh = _projectToSurface(
          mesh, originalBvh, preserveBoundary, constraints(mesh));
    }
    progress?.call(iterations, iterations);
    mesh.removeDegenerateFaces();
    mesh.compact();
    if (adaptiveDensity > 0) Weld.removeDuplicateFaces(mesh);
    final outputTopology = MeshTopology(mesh);
    final inputTopology = MeshTopology(input);
    if (adaptiveDensity > 0 &&
        (outputTopology.nonManifoldEdges().isNotEmpty ||
            inputTopology.nonManifoldEdges().isNotEmpty ||
            (inputTopology.boundaryEdges().isEmpty &&
                outputTopology.boundaryEdges().isNotEmpty))) {
      // The angle-defect density heuristic can create non-manifold junctions
      // on aggressive settings. Fall back to the uniform pass, which is
      // topology-safe, rather than returning a non-manifold result.
      return RemeshResult(
        remesh(
          input,
          targetEdgeLength: targetEdgeLength,
          iterations: iterations,
          preserveBoundary: preserveBoundary,
          preserveSharp: preserveSharp,
          sharpAngleDegrees: sharpAngleDegrees,
          preserveGroupBoundaries: preserveGroupBoundaries,
          adaptiveDensity: 0.0,
          debugTopology: debugTopology,
          progress: progress,
          maximumFaces: maximumFaces,
        ),
        usedUniformFallback: true,
        fallbackReason: 'adaptive remesh produced non-manifold edges',
      );
    }
    if (input.faceGroups != null) {
      mesh.faceGroups = _transferFaceGroups(input, mesh, originalBvh);
    }
    mesh.vertexColors =
        transferVertexColors(input, mesh, sourceBvh: originalBvh);
    return RemeshResult(mesh);
  }

  /// Endpoints of every edge whose adjacent faces carry different group ids.
  static List<List<double>> _groupBoundarySegments(TriMesh mesh) {
    final groups = mesh.faceGroups;
    if (groups == null) return const <List<double>>[];
    final topo = MeshTopology(mesh);
    final out = <List<double>>[];
    for (final entry in topo.edgeFaces.entries) {
      final faces = entry.value;
      if (faces.length != 2) continue;
      final g0 = faces[0] < groups.length ? groups[faces[0]] : 0;
      final g1 = faces[1] < groups.length ? groups[faces[1]] : 0;
      if (g0 == g1) continue;
      final a = entry.key ~/ mesh.vertexCount;
      final b = entry.key % mesh.vertexCount;
      out.add(<double>[mesh.vx(a), mesh.vy(a), mesh.vz(a)]);
      out.add(<double>[mesh.vx(b), mesh.vy(b), mesh.vz(b)]);
    }
    return out;
  }

  /// Vertices within [tolerance] of a group-boundary segment.
  static Set<int> _verticesNearSegments(
      TriMesh mesh, List<List<double>> segments, double tolerance) {
    final out = <int>{};
    final t2 = tolerance * tolerance;
    for (var v = 0; v < mesh.vertexCount; v++) {
      final px = mesh.vx(v), py = mesh.vy(v), pz = mesh.vz(v);
      for (var s = 0; s < segments.length; s += 2) {
        if (_pointSegmentDistSq(px, py, pz, segments[s], segments[s + 1]) <=
            t2) {
          out.add(v);
          break;
        }
      }
    }
    return out;
  }

  static double _pointSegmentDistSq(
      double px, double py, double pz, List<double> a, List<double> b) {
    final abx = b[0] - a[0], aby = b[1] - a[1], abz = b[2] - a[2];
    final apx = px - a[0], apy = py - a[1], apz = pz - a[2];
    final denom = abx * abx + aby * aby + abz * abz;
    var t = denom <= 1e-20 ? 0.0 : (apx * abx + apy * aby + apz * abz) / denom;
    t = t.clamp(0.0, 1.0);
    final dx = apx - abx * t, dy = apy - aby * t, dz = apz - abz * t;
    return dx * dx + dy * dy + dz * dz;
  }

  /// Assigns each output face the group of the nearest input face, so group
  /// regions survive remeshing even though split/collapse rebuild the mesh.
  static Uint16List _transferFaceGroups(
      TriMesh source, TriMesh output, TriangleBVH sourceBvh) {
    final groups = source.faceGroups;
    final out = Uint16List(output.faceCount);
    if (groups == null) return out;
    for (var f = 0; f < output.faceCount; f++) {
      final i0 = output.indices[f * 3];
      final i1 = output.indices[f * 3 + 1];
      final i2 = output.indices[f * 3 + 2];
      final cx = (output.vx(i0) + output.vx(i1) + output.vx(i2)) / 3;
      final cy = (output.vy(i0) + output.vy(i1) + output.vy(i2)) / 3;
      final cz = (output.vz(i0) + output.vz(i1) + output.vz(i2)) / 3;
      final hit = sourceBvh.closestPoint(cx, cy, cz);
      if (hit != null && hit.face >= 0 && hit.face < groups.length) {
        out[f] = groups[hit.face];
      }
    }
    return out;
  }

  static Set<int> _sharpVertices(TriMesh mesh, double angleRad) {
    final topo = MeshTopology(mesh);
    final out = <int>{};
    final cosLimit = math.cos(angleRad);
    for (final entry in topo.edgeFaces.entries) {
      if (entry.value.length != 2) continue;
      final f0 = entry.value[0], f1 = entry.value[1];
      final n0 = _faceNormal(mesh, f0), n1 = _faceNormal(mesh, f1);
      final d = n0[0] * n1[0] + n0[1] * n1[1] + n0[2] * n1[2];
      if (d < cosLimit) {
        final n = mesh.vertexCount;
        out.add(entry.key ~/ n);
        out.add(entry.key % n);
      }
    }
    return out;
  }

  static List<double> _faceNormal(TriMesh m, int f) {
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

  /// Per-vertex normalized curvature (angle defect), used by adaptive density.
  static List<double> _curvature(TriMesh mesh) {
    final topo = MeshTopology(mesh);
    final sum = List<double>.filled(mesh.vertexCount, 0.0);
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3];
      final b = mesh.indices[f * 3 + 1];
      final c = mesh.indices[f * 3 + 2];
      void angleAt(int v, int p, int q) {
        final ux = mesh.vx(p) - mesh.vx(v);
        final uy = mesh.vy(p) - mesh.vy(v);
        final uz = mesh.vz(p) - mesh.vz(v);
        final wx = mesh.vx(q) - mesh.vx(v);
        final wy = mesh.vy(q) - mesh.vy(v);
        final wz = mesh.vz(q) - mesh.vz(v);
        final lu = math.sqrt(ux * ux + uy * uy + uz * uz);
        final lw = math.sqrt(wx * wx + wy * wy + wz * wz);
        if (lu < 1e-20 || lw < 1e-20) return;
        final cosA =
            ((ux * wx + uy * wy + uz * wz) / (lu * lw)).clamp(-1.0, 1.0);
        sum[v] += math.acos(cosA);
      }

      angleAt(a, b, c);
      angleAt(b, c, a);
      angleAt(c, a, b);
    }
    final boundary = <int>{};
    for (final e in topo.boundaryEdges()) {
      boundary.add(e[0]);
      boundary.add(e[1]);
    }
    final defect = List<double>.filled(mesh.vertexCount, 0.0);
    var maxDefect = 0.0;
    for (var v = 0; v < mesh.vertexCount; v++) {
      final full = boundary.contains(v) ? math.pi : 2 * math.pi;
      final d = (full - sum[v]).clamp(0.0, full);
      defect[v] = d;
      if (d > maxDefect) maxDefect = d;
    }
    if (maxDefect < 1e-20) return List<double>.filled(mesh.vertexCount, 0.0);
    for (var v = 0; v < defect.length; v++) {
      defect[v] /= maxDefect;
    }
    return defect;
  }

  /// Splits every edge longer than [maxLen]. Handles faces with one, two or
  /// three long edges so the result stays conforming.
  static TriMesh _splitLong(TriMesh mesh, double maxLen,
      {double Function(int, int)? maxFor,
      required int maximumFaces,
      bool preserveBoundary = false}) {
    final midCache = <int, int>{};
    final n = mesh.vertexCount;
    final topo = MeshTopology(mesh);
    final splitEdges = <int>{};
    for (final key in topo.edgeFaces.keys) {
      if (preserveBoundary && topo.edgeFaces[key]!.length == 1) continue;
      final a = key ~/ n, b = key % n;
      if (_len(mesh, a, b) > (maxFor?.call(a, b) ?? maxLen)) {
        splitEdges.add(key);
      }
    }
    var predictedFaces = mesh.faceCount;
    for (var f = 0; f < mesh.faceCount; f++) {
      for (var k = 0; k < 3; k++) {
        if (splitEdges.contains(topo.edgeKey(
            mesh.indices[f * 3 + k], mesh.indices[f * 3 + (k + 1) % 3]))) {
          predictedFaces++;
        }
      }
    }
    checkGeneratedSize(predictedFaces, mesh.vertexCount + splitEdges.length,
        maximumFaces, 'Remesh subdivision');
    final builder = MeshBuilder();
    final vmap = List<int>.generate(mesh.vertexCount,
        (v) => builder.addVertex(mesh.vx(v), mesh.vy(v), mesh.vz(v)));

    int midpoint(int a, int b) {
      final key = a < b ? a * n + b : b * n + a;
      final cached = midCache[key];
      if (cached != null) return cached;
      final id = builder.addVertex(
        (mesh.vx(a) + mesh.vx(b)) * 0.5,
        (mesh.vy(a) + mesh.vy(b)) * 0.5,
        (mesh.vz(a) + mesh.vz(b)) * 0.5,
      );
      midCache[key] = id;
      return id;
    }

    for (var f = 0; f < mesh.faceCount; f++) {
      final va = mesh.indices[f * 3],
          vb = mesh.indices[f * 3 + 1],
          vc = mesh.indices[f * 3 + 2];
      final ab = splitEdges.contains(topo.edgeKey(va, vb));
      final bc = splitEdges.contains(topo.edgeKey(vb, vc));
      final ca = splitEdges.contains(topo.edgeKey(vc, va));
      final A = vmap[va], B = vmap[vb], C = vmap[vc];
      final count = (ab ? 1 : 0) + (bc ? 1 : 0) + (ca ? 1 : 0);
      if (count == 0) {
        builder.addTriangle(A, B, C);
        continue;
      }
      if (count == 1) {
        if (ab) {
          final m = midpoint(va, vb);
          builder.addTriangle(A, m, C);
          builder.addTriangle(m, B, C);
        } else if (bc) {
          final m = midpoint(vb, vc);
          builder.addTriangle(A, B, m);
          builder.addTriangle(A, m, C);
        } else {
          final m = midpoint(vc, va);
          builder.addTriangle(A, B, m);
          builder.addTriangle(m, B, C);
        }
        continue;
      }
      if (count == 2) {
        if (!ca) {
          // ab and bc long: split into 3.
          final m1 = midpoint(va, vb), m2 = midpoint(vb, vc);
          builder.addTriangle(A, m1, m2);
          builder.addTriangle(A, m2, C);
          builder.addTriangle(m1, B, m2);
        } else if (!ab) {
          final m1 = midpoint(vb, vc), m2 = midpoint(vc, va);
          builder.addTriangle(A, B, m1);
          builder.addTriangle(A, m1, m2);
          builder.addTriangle(m2, m1, C);
        } else {
          final m1 = midpoint(vc, va), m2 = midpoint(va, vb);
          builder.addTriangle(A, m2, m1);
          builder.addTriangle(m2, B, C);
          builder.addTriangle(m1, m2, C);
        }
        continue;
      }
      // All three long: centre fan.
      final m1 = midpoint(va, vb), m2 = midpoint(vb, vc), m3 = midpoint(vc, va);
      builder.addTriangle(A, m1, m3);
      builder.addTriangle(m1, B, m2);
      builder.addTriangle(m2, C, m3);
      builder.addTriangle(m1, m2, m3);
    }
    return builder.build();
  }

  static double _len(TriMesh m, int a, int b) {
    final dx = m.vx(a) - m.vx(b),
        dy = m.vy(a) - m.vy(b),
        dz = m.vz(a) - m.vz(b);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// Collapses edges shorter than [minLen] when the collapse keeps the mesh
  /// manifold and does not invert any incident triangle.
  static TriMesh _collapseShort(
      TriMesh mesh, double minLen, bool preserveBoundary, Set<int> sharp,
      {double Function(int, int)? minFor}) {
    final state = CollapseMesh(mesh);
    final pinned = <int>{
      ...sharp,
      if (preserveBoundary)
        for (final e in MeshTopology(mesh).boundaryEdges()) ...e.take(2)
    };
    final n = mesh.vertexCount;
    final edges = state.edgeCount.keys.toList()
      ..sort((a, b) {
        final la = _len(mesh, a ~/ n, a % n);
        final lb = _len(mesh, b ~/ n, b % n);
        return la.compareTo(lb);
      });
    for (final key in edges) {
      if ((state.edgeCount[key] ?? 0) == 0) continue;
      final a = key ~/ n, b = key % n;
      final dx = state.positions[a * 3] - state.positions[b * 3];
      final dy = state.positions[a * 3 + 1] - state.positions[b * 3 + 1];
      final dz = state.positions[a * 3 + 2] - state.positions[b * 3 + 2];
      if (math.sqrt(dx * dx + dy * dy + dz * dz) >=
          (minFor?.call(a, b) ?? minLen)) {
        continue;
      }
      final anchor = pinned.contains(a)
          ? a
          : pinned.contains(b)
              ? b
              : null;
      final collapsed = state.tryCollapse(
        a,
        b,
        anchor == null
            ? (state.positions[a * 3] + state.positions[b * 3]) * .5
            : state.positions[anchor * 3],
        anchor == null
            ? (state.positions[a * 3 + 1] + state.positions[b * 3 + 1]) * .5
            : state.positions[anchor * 3 + 1],
        anchor == null
            ? (state.positions[a * 3 + 2] + state.positions[b * 3 + 2]) * .5
            : state.positions[anchor * 3 + 2],
        preserveBoundary: preserveBoundary,
        sharp: pinned,
      );
      if (collapsed && anchor != null) {
        pinned.remove(b);
        pinned.add(a);
      }
    }
    final out = state.build();
    out.removeDegenerateFaces();
    out.compact();
    return out;
  }

  /// Flips interior edges when the flip reduces deviation from valence six.
  static TriMesh _flipForValence(
      TriMesh mesh, bool preserveBoundary, Set<int> sharp) {
    final topo = MeshTopology(mesh);
    final n = mesh.vertexCount;
    final boundary = <int>{};
    if (preserveBoundary) {
      for (final e in topo.boundaryEdges()) {
        boundary.add(e[0]);
        boundary.add(e[1]);
      }
    }
    // Work on a mutable face list.
    final faces = <List<int>>[];
    for (var f = 0; f < mesh.faceCount; f++) {
      faces.add(<int>[
        mesh.indices[f * 3],
        mesh.indices[f * 3 + 1],
        mesh.indices[f * 3 + 2]
      ]);
    }
    final valence = List<int>.generate(n, (v) => topo.valence(v));
    final flipped = <int>{};

    for (final entry in topo.edgeFaces.entries) {
      if (entry.value.length != 2) continue;
      final a = entry.key ~/ n, b = entry.key % n;
      if (sharp.contains(a) && sharp.contains(b)) continue;
      if (preserveBoundary && (boundary.contains(a) || boundary.contains(b))) {
        continue;
      }
      final f0 = entry.value[0], f1 = entry.value[1];
      if (flipped.contains(f0) || flipped.contains(f1)) continue;
      if (!faces[f0].contains(a) || !faces[f0].contains(b)) continue;
      if (!faces[f1].contains(a) || !faces[f1].contains(b)) continue;
      // Find the opposite vertices.
      int? c, d;
      for (final v in faces[f0]) {
        if (v != a && v != b) c = v;
      }
      for (final v in faces[f1]) {
        if (v != a && v != b) d = v;
      }
      if (c == null || d == null) continue;
      if (c == d) continue;
      // Flipping to c-d is only legal if c-d is not already an edge.
      if (_edgeExists(faces, c, d)) continue;
      final before = (valence[a] - 6).abs() +
          (valence[b] - 6).abs() +
          (valence[c] - 6).abs() +
          (valence[d] - 6).abs();
      final after = (valence[a] - 7).abs() +
          (valence[b] - 7).abs() +
          (valence[c] - 5).abs() +
          (valence[d] - 5).abs();
      if (after >= before) continue;
      // Replace the two faces with (a,c,d) and (c,b,d), preserving the
      // original winding by comparing normals.
      final orig0 = _faceNormal(mesh, f0);
      final orig1 = _faceNormal(mesh, f1);
      final t0 = _normalOf(mesh, a, c, d);
      final t1 = _normalOf(mesh, c, b, d);
      final d0 = t0[0] * orig0[0] + t0[1] * orig0[1] + t0[2] * orig0[2];
      final d1 = t1[0] * orig1[0] + t1[1] * orig1[1] + t1[2] * orig1[2];
      if (d0.abs() < 1e-12 || d1.abs() < 1e-12 || d0 * d1 <= 0) continue;
      faces[f0] = d0 > 0 ? <int>[a, c, d] : <int>[a, d, c];
      faces[f1] = d1 > 0 ? <int>[c, b, d] : <int>[c, d, b];
      valence[a]--;
      valence[b]--;
      valence[c]++;
      valence[d]++;
      flipped.add(f0);
      flipped.add(f1);
    }

    final builder = MeshBuilder();
    for (var v = 0; v < n; v++) {
      builder.addVertex(mesh.vx(v), mesh.vy(v), mesh.vz(v));
    }
    for (final f in faces) {
      if (f[0] == f[1] || f[1] == f[2] || f[0] == f[2]) continue;
      builder.addTriangle(f[0], f[1], f[2]);
    }
    final out = builder.build();
    out.removeDegenerateFaces();
    return out;
  }

  static bool _edgeExists(List<List<int>> faces, int a, int b) {
    for (final f in faces) {
      var hasA = false, hasB = false;
      for (final v in f) {
        if (v == a) hasA = true;
        if (v == b) hasB = true;
      }
      if (hasA && hasB) return true;
    }
    return false;
  }

  static List<double> _normalOf(TriMesh m, int a, int b, int c) {
    final ux = m.vx(b) - m.vx(a),
        uy = m.vy(b) - m.vy(a),
        uz = m.vz(b) - m.vz(a);
    final wx = m.vx(c) - m.vx(a),
        wy = m.vy(c) - m.vy(a),
        wz = m.vz(c) - m.vz(a);
    var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-20) return <double>[0, 0, 0];
    return <double>[nx / l, ny / l, nz / l];
  }

  /// Tangential Laplacian relaxation: move toward the neighbour centroid, but
  /// only within the tangent plane, so the surface does not shrink.
  static TriMesh _tangentialRelax(TriMesh mesh, TriangleBVH original,
      bool preserveBoundary, Set<int> sharp) {
    final topo = MeshTopology(mesh);
    final boundary = <int>{};
    if (preserveBoundary) {
      for (final e in topo.boundaryEdges()) {
        boundary.add(e[0]);
        boundary.add(e[1]);
      }
    }
    final next = Float32List.fromList(mesh.positions);
    final normals = Float32List(mesh.vertexCount * 3);
    for (var v = 0; v < mesh.vertexCount; v++) {
      final nrm = _vertexNormal(mesh, v, topo);
      normals[v * 3] = nrm[0];
      normals[v * 3 + 1] = nrm[1];
      normals[v * 3 + 2] = nrm[2];
    }
    for (var v = 0; v < mesh.vertexCount; v++) {
      if (preserveBoundary && boundary.contains(v)) continue;
      if (sharp.contains(v)) continue;
      final nb = topo.neighborsOfVertex(v);
      if (nb.length < 3) continue;
      var cx = 0.0, cy = 0.0, cz = 0.0;
      for (final w in nb) {
        cx += mesh.vx(w);
        cy += mesh.vy(w);
        cz += mesh.vz(w);
      }
      cx /= nb.length;
      cy /= nb.length;
      cz /= nb.length;
      var dx = cx - mesh.vx(v), dy = cy - mesh.vy(v), dz = cz - mesh.vz(v);
      // Project displacement onto the vertex tangent plane.
      final nrm = <double>[
        normals[v * 3],
        normals[v * 3 + 1],
        normals[v * 3 + 2]
      ];
      final d = dx * nrm[0] + dy * nrm[1] + dz * nrm[2];
      dx -= d * nrm[0];
      dy -= d * nrm[1];
      dz -= d * nrm[2];
      next[v * 3] = mesh.vx(v) + 0.5 * dx;
      next[v * 3 + 1] = mesh.vy(v) + 0.5 * dy;
      next[v * 3 + 2] = mesh.vz(v) + 0.5 * dz;
    }
    mesh.positions = next;
    return mesh;
  }

  static List<double> _vertexNormal(TriMesh m, int v, [MeshTopology? cached]) {
    final topo = cached ?? MeshTopology(m);
    var nx = 0.0, ny = 0.0, nz = 0.0;
    for (final f in topo.facesOfVertex(v)) {
      final n = _faceNormal(m, f);
      nx += n[0];
      ny += n[1];
      nz += n[2];
    }
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-20) return <double>[0, 0, 1];
    return <double>[nx / l, ny / l, nz / l];
  }

  /// Snaps vertices back onto the original surface (shape preservation).
  static TriMesh _projectToSurface(TriMesh mesh, TriangleBVH original,
      bool preserveBoundary, Set<int> sharp) {
    final topo = MeshTopology(mesh);
    final boundary = <int>{};
    if (preserveBoundary) {
      for (final e in topo.boundaryEdges()) {
        boundary.add(e[0]);
        boundary.add(e[1]);
      }
    }
    for (var v = 0; v < mesh.vertexCount; v++) {
      if (preserveBoundary && boundary.contains(v)) continue;
      if (sharp.contains(v)) continue;
      final cp = original.closestPoint(mesh.vx(v), mesh.vy(v), mesh.vz(v));
      if (cp == null) continue;
      // Only project when we are already close to the surface, otherwise the
      // projection would collapse unrelated parts of the mesh together.
      final b = original.mesh.bounds();
      final limit = b.diagonal * 0.02;
      if (cp.distance > limit) continue;
      mesh.positions[v * 3] = cp.point[0];
      mesh.positions[v * 3 + 1] = cp.point[1];
      mesh.positions[v * 3 + 2] = cp.point[2];
    }
    return mesh;
  }
}
