import 'dart:math' as math;
import 'dart:typed_data';

import '../geom/bbox.dart';
import '../spatial/bvh.dart';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';

/// Defect classes surfaced by Meshmixer's Inspector (observed strings:
/// blue = hole, red = non-manifold, magenta = small disconnected component).
enum DefectKind {
  hole,
  nonManifoldEdge,
  nonManifoldVertex,
  smallComponent,
  selfIntersection
}

class MeshDefect {
  final DefectKind kind;
  final List<int> vertices;
  final List<int> faces;
  final double metric;

  MeshDefect(this.kind,
      {required this.vertices, required this.faces, required this.metric});

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'vertices': vertices.length,
        'faces': faces.length,
        'metric': metric,
      };
}

class MeshInspector {
  /// Scans for the defect set Meshmixer reports. [smallComponentArea] is the
  /// absolute area below which a disconnected shell is flagged.
  static List<MeshDefect> scan(TriMesh mesh,
      {double smallComponentArea = double.infinity,
      bool checkSelfIntersections = false}) {
    final topo = MeshTopology(mesh);
    final defects = <MeshDefect>[];

    for (final loop in topo.boundaryLoops()) {
      var perimeter = 0.0;
      for (var i = 0; i < loop.length; i++) {
        final a = loop[i], b = loop[(i + 1) % loop.length];
        perimeter += _dist(mesh, a, b);
      }
      final faces = <int>[];
      for (var i = 0; i < loop.length; i++) {
        final k = topo.edgeKey(loop[i], loop[(i + 1) % loop.length]);
        faces.addAll(topo.edgeFaces[k] ?? const <int>[]);
      }
      defects.add(MeshDefect(DefectKind.hole,
          vertices: loop, faces: faces.toSet().toList(), metric: perimeter));
    }

    for (final e in topo.nonManifoldEdges()) {
      final faces = topo.edgeFaces[topo.edgeKey(e[0], e[1])] ?? const <int>[];
      defects.add(MeshDefect(DefectKind.nonManifoldEdge,
          vertices: <int>[e[0], e[1]], faces: faces, metric: e[2].toDouble()));
    }

    for (final v in topo.nonManifoldVertices()) {
      defects.add(MeshDefect(DefectKind.nonManifoldVertex,
          vertices: <int>[v], faces: topo.facesOfVertex(v), metric: 0));
    }

    final (faceComp, compCount) = topo.components();
    if (compCount > 1) {
      final areas = List<double>.filled(compCount, 0);
      final componentFaces = List.generate(compCount, (_) => <int>[]);
      for (var f = 0; f < mesh.faceCount; f++) {
        areas[faceComp[f]] += _faceArea(mesh, f);
        componentFaces[faceComp[f]].add(f);
      }
      for (var c = 0; c < compCount; c++) {
        if (areas[c] > smallComponentArea) continue;
        final faces = <int>[];
        final verts = <int>{};
        for (final f in componentFaces[c]) {
          faces.add(f);
          verts.addAll(<int>[
            mesh.indices[f * 3],
            mesh.indices[f * 3 + 1],
            mesh.indices[f * 3 + 2],
          ]);
        }
        defects.add(MeshDefect(DefectKind.smallComponent,
            vertices: verts.toList(), faces: faces, metric: areas[c]));
      }
    }

    if (checkSelfIntersections) {
      defects.addAll(_selfIntersections(mesh));
    }
    return defects;
  }

  /// Separates vertex fans across edges with other than two incident faces.
  /// Each (original vertex, incident face) gets its own fan mapping. Geometry,
  /// face order, corner UVs, materials, groups and vertex colors are preserved.
  /// Splitting can introduce boundaries; it does not claim to produce a solid.
  static TriMesh splitNonManifold(TriMesh mesh) {
    final topo = MeshTopology(mesh);
    final positions = <double>[...mesh.positions];
    final colors =
        mesh.vertexColors == null ? null : <double>[...mesh.vertexColors!];
    final indices = Uint32List.fromList(mesh.indices);
    for (var v = 0; v < mesh.vertexCount; v++) {
      final remaining = topo.facesOfVertex(v).toSet();
      var first = true;
      while (remaining.isNotEmpty) {
        final mapped = first ? v : positions.length ~/ 3;
        if (!first) {
          positions.addAll([mesh.vx(v), mesh.vy(v), mesh.vz(v)]);
          colors?.addAll(mesh.vertexColors!.sublist(v * 3, v * 3 + 3));
        }
        first = false;
        final seed = remaining.first;
        remaining.remove(seed);
        final stack = [seed];
        while (stack.isNotEmpty) {
          final f = stack.removeLast();
          for (var k = 0; k < 3; k++) {
            if (mesh.indices[f * 3 + k] == v) indices[f * 3 + k] = mapped;
            final a = mesh.indices[f * 3 + k];
            final b = mesh.indices[f * 3 + (k + 1) % 3];
            if (a != v && b != v) continue;
            final adjacent = topo.edgeFaces[topo.edgeKey(a, b)]!;
            if (adjacent.length != 2) continue;
            for (final g in adjacent) {
              if (remaining.remove(g)) stack.add(g);
            }
          }
        }
      }
    }
    final out = mesh.clone();
    out.positions = Float32List.fromList(positions);
    out.indices = indices;
    out.vertexColors = colors == null ? null : Float32List.fromList(colors);
    return out;
  }

  /// BVH broad phase followed by a separating-axis triangle test, including
  /// coplanar axes. Exhausting the reporting budget fails explicitly: a partial
  /// inspection must never be presented as a clean mesh.
  static List<MeshDefect> _selfIntersections(TriMesh mesh, {int limit = 5000}) {
    final bvh = TriangleBVH.build(mesh);
    final out = <MeshDefect>[];
    for (var f = 0; f < mesh.faceCount; f++) {
      final box = _faceBox(mesh, f);
      for (final g in bvh.overlap(
          BBox.fromBounds(box[0], box[1], box[2], box[3], box[4], box[5]),
          exact: true)) {
        if (g <= f) continue;
        if (_triTri(mesh, f, g)) {
          if (out.length >= limit) {
            throw StateError(
                'Intersection report limit exceeded ($limit); inspection incomplete');
          }
          out.add(MeshDefect(DefectKind.selfIntersection,
              vertices: {
                ...mesh.indices.sublist(f * 3, f * 3 + 3),
                ...mesh.indices.sublist(g * 3, g * 3 + 3)
              }.toList(),
              faces: [f, g],
              metric: 0));
        }
      }
    }
    return out;
  }

  static List<double> _faceBox(TriMesh m, int f) {
    var minx = double.infinity, miny = double.infinity, minz = double.infinity;
    var maxx = double.negativeInfinity,
        maxy = double.negativeInfinity,
        maxz = double.negativeInfinity;
    for (var k = 0; k < 3; k++) {
      final v = m.indices[f * 3 + k];
      minx = math.min(minx, m.vx(v));
      miny = math.min(miny, m.vy(v));
      minz = math.min(minz, m.vz(v));
      maxx = math.max(maxx, m.vx(v));
      maxy = math.max(maxy, m.vy(v));
      maxz = math.max(maxz, m.vz(v));
    }
    return <double>[minx, miny, minz, maxx, maxy, maxz];
  }

  static bool _shareVertex(TriMesh m, int f, int g) {
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        if (m.indices[f * 3 + i] == m.indices[g * 3 + j]) return true;
      }
    }
    return false;
  }

  /// Separating-axis test for two triangles.
  static bool _triTri(TriMesh m, int f, int g) {
    final ta = _triVerts(m, f);
    final tb = _triVerts(m, g);
    // Move adjacent triangles slightly into their relative interiors so a
    // shared edge/vertex alone is not reported as an intersection. Normalize
    // around a local origin to avoid scale- and translation-dependent tests.
    final origin = List<double>.from(ta[0]);
    var scale = 0.0;
    for (final p in [...ta, ...tb]) {
      for (var k = 0; k < 3; k++) {
        p[k] -= origin[k];
        scale = math.max(scale, p[k].abs());
      }
    }
    if (scale == 0) return false;
    for (final t in [ta, tb]) {
      for (final p in t) {
        for (var k = 0; k < 3; k++) {
          p[k] /= scale;
        }
      }
      if (_shareVertex(m, f, g)) {
        final center = [
          for (var k = 0; k < 3; k++) (t[0][k] + t[1][k] + t[2][k]) / 3
        ];
        for (final p in t) {
          for (var k = 0; k < 3; k++) {
            p[k] += (center[k] - p[k]) * 1e-7;
          }
        }
      }
    }
    final axes = <List<double>>[];
    final na = _cross(_sub(ta[1], ta[0]), _sub(ta[2], ta[0]));
    final nb = _cross(_sub(tb[1], tb[0]), _sub(tb[2], tb[0]));
    axes.add(na);
    axes.add(nb);
    for (var i = 0; i < 3; i++) {
      final ea = _sub(ta[(i + 1) % 3], ta[i]);
      axes.add(_cross(na, ea));
      axes.add(_cross(nb, _sub(tb[(i + 1) % 3], tb[i])));
      for (var j = 0; j < 3; j++) {
        final eb = _sub(tb[(j + 1) % 3], tb[j]);
        axes.add(_cross(ea, eb));
      }
    }
    for (final ax in axes) {
      final l = math.sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
      if (l < 1e-12) continue;
      final nx = ax[0] / l, ny = ax[1] / l, nz = ax[2] / l;
      var amin = double.infinity, amax = double.negativeInfinity;
      var bmin = double.infinity, bmax = double.negativeInfinity;
      for (final p in ta) {
        final d = p[0] * nx + p[1] * ny + p[2] * nz;
        if (d < amin) amin = d;
        if (d > amax) amax = d;
      }
      for (final p in tb) {
        final d = p[0] * nx + p[1] * ny + p[2] * nz;
        if (d < bmin) bmin = d;
        if (d > bmax) bmax = d;
      }
      if (amax < bmin || bmax < amin) return false;
    }
    return true;
  }

  static List<List<double>> _triVerts(TriMesh m, int f) => <List<double>>[
        <double>[
          m.vx(m.indices[f * 3]),
          m.vy(m.indices[f * 3]),
          m.vz(m.indices[f * 3])
        ],
        <double>[
          m.vx(m.indices[f * 3 + 1]),
          m.vy(m.indices[f * 3 + 1]),
          m.vz(m.indices[f * 3 + 1])
        ],
        <double>[
          m.vx(m.indices[f * 3 + 2]),
          m.vy(m.indices[f * 3 + 2]),
          m.vz(m.indices[f * 3 + 2])
        ],
      ];

  static List<double> _sub(List<double> a, List<double> b) =>
      <double>[a[0] - b[0], a[1] - b[1], a[2] - b[2]];

  static List<double> _cross(List<double> a, List<double> b) => <double>[
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];

  static double _dist(TriMesh m, int a, int b) {
    final dx = m.vx(a) - m.vx(b),
        dy = m.vy(a) - m.vy(b),
        dz = m.vz(a) - m.vz(b);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  static double _faceArea(TriMesh m, int f) {
    final a = m.indices[f * 3],
        b = m.indices[f * 3 + 1],
        c = m.indices[f * 3 + 2];
    final ux = m.vx(b) - m.vx(a),
        uy = m.vy(b) - m.vy(a),
        uz = m.vz(b) - m.vz(a);
    final wx = m.vx(c) - m.vx(a),
        wy = m.vy(c) - m.vy(a),
        wz = m.vz(c) - m.vz(a);
    final nx = uy * wz - uz * wy,
        ny = uz * wx - ux * wz,
        nz = ux * wy - uy * wx;
    return 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz);
  }
}
