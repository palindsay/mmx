import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../repair/weld.dart';

/// Mirror across a plane, optionally welding the seam.
///
/// Corresponds to Meshmixer's Mirror tool (libmeshtools/Operators/MeshMirror.cpp
/// and meshmixer/tools MirrorTool.cpp).
class Mirror {
  /// [point] and [normal] define the mirror plane. When [keepOriginal] is true
  /// the result is original + reflected copy; otherwise only the reflection is
  /// returned (matching "mirror the object to the other side").
  static TriMesh mirror(
    TriMesh mesh, {
    required List<double> point,
    required List<double> normal,
    bool keepOriginal = true,
    double weldTolerance = 0,
    bool flipNormals = true,
  }) {
    if (point.length != 3 ||
        normal.length != 3 ||
        point.any((v) => !v.isFinite) ||
        normal.any((v) => !v.isFinite) ||
        !weldTolerance.isFinite ||
        weldTolerance < 0) {
      throw ArgumentError('Invalid mirror plane or weld tolerance');
    }
    final nl = math.sqrt(
        normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
    if (nl < 1e-12) return mesh.clone();
    final nx = normal[0] / nl, ny = normal[1] / nl, nz = normal[2] / nl;

    final builder = MeshBuilder();
    if (keepOriginal) {
      for (var i = 0; i < mesh.vertexCount; i++) {
        builder.addVertex(mesh.vx(i), mesh.vy(i), mesh.vz(i));
      }
      for (var f = 0; f < mesh.faceCount; f++) {
        builder.addTriangle(mesh.indices[f * 3], mesh.indices[f * 3 + 1],
            mesh.indices[f * 3 + 2]);
      }
    }
    final offset = builder.vertexCount;
    for (var i = 0; i < mesh.vertexCount; i++) {
      final x = mesh.vx(i), y = mesh.vy(i), z = mesh.vz(i);
      final d = (x - point[0]) * nx + (y - point[1]) * ny + (z - point[2]) * nz;
      builder.addVertex(x - 2 * d * nx, y - 2 * d * ny, z - 2 * d * nz);
    }
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = offset + mesh.indices[f * 3];
      final b = offset + mesh.indices[f * 3 + 1];
      final c = offset + mesh.indices[f * 3 + 2];
      // Reflection reverses handedness, so flip the winding to keep normals
      // pointing outward.
      if (flipNormals) {
        builder.addTriangle(a, c, b);
      } else {
        builder.addTriangle(a, b, c);
      }
    }
    var out = builder.build()
      ..faceGroups = mesh.faceGroups == null
          ? null
          : Uint16List.fromList([
              if (keepOriginal) ...mesh.faceGroups!,
              ...mesh.faceGroups!,
            ])
      ..vertexColors = mesh.vertexColors == null
          ? null
          : Float32List.fromList([
              if (keepOriginal) ...mesh.vertexColors!,
              ...mesh.vertexColors!,
            ])
      ..materials = mesh.materials
      ..faceMaterials = mesh.faceMaterials == null
          ? null
          : Uint16List.fromList([
              if (keepOriginal) ...mesh.faceMaterials!,
              ...mesh.faceMaterials!
            ])
      ..cornerUvs = mesh.cornerUvs == null
          ? null
          : Float32List.fromList([
              if (keepOriginal) ...mesh.cornerUvs!,
              for (var f = 0; f < mesh.faceCount; f++)
                for (final k in (flipNormals ? [0, 2, 1] : [0, 1, 2])) ...[
                  mesh.cornerUvs![f * 6 + k * 2],
                  mesh.cornerUvs![f * 6 + k * 2 + 1]
                ]
            ]);
    out.removeDegenerateFaces(minArea: 0);
    if (weldTolerance > 0) {
      out = WeldLike.weld(out, weldTolerance);
    }
    out.compact();
    return out;
  }
}

/// Compatibility wrapper shared by existing mirror/merge callers.
class WeldLike {
  static TriMesh weld(TriMesh mesh, double tolerance) =>
      Weld.weldVertices(mesh, tolerance: tolerance);
}

/// Extrudes a face selection along the surface normal, adding side walls.
///
/// Matches Meshmixer's Extrude tool (SurfaceExtruder.cpp / ExtrudeTool.cpp):
/// the selected region is pushed out and a skirt is built from its boundary.
class Extruder {
  static TriMesh extrude(
    TriMesh mesh, {
    required Uint8List faceMask,
    required double distance,
    bool smoothBoundary = false,
    int smoothIterations = 4,
  }) {
    mesh.requireUntextured('Extrude');
    if (faceMask.length != mesh.faceCount ||
        !distance.isFinite ||
        smoothIterations < 0 ||
        smoothIterations > 1000) {
      throw ArgumentError('Invalid extrusion parameters');
    }
    if (distance.abs() < 1e-9) return mesh.clone();
    final topo = MeshTopology(mesh);
    final n = mesh.vertexCount;

    // Region normal: area-weighted average of selected face normals.
    var rx = 0.0, ry = 0.0, rz = 0.0;
    var selectedCount = 0;
    for (var f = 0; f < mesh.faceCount; f++) {
      if (faceMask[f] == 0) continue;
      selectedCount++;
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ux = mesh.vx(b) - mesh.vx(a),
          uy = mesh.vy(b) - mesh.vy(a),
          uz = mesh.vz(b) - mesh.vz(a);
      final wx = mesh.vx(c) - mesh.vx(a),
          wy = mesh.vy(c) - mesh.vy(a),
          wz = mesh.vz(c) - mesh.vz(a);
      rx += uy * wz - uz * wy;
      ry += uz * wx - ux * wz;
      rz += ux * wy - uy * wx;
    }
    if (selectedCount == 0) return mesh.clone();
    final rl = math.sqrt(rx * rx + ry * ry + rz * rz);
    if (rl < 1e-12) return mesh.clone();
    rx /= rl;
    ry /= rl;
    rz /= rl;

    final builder = MeshBuilder();
    final colors =
        mesh.vertexColors == null ? null : <double>[...mesh.vertexColors!];
    final groups = mesh.faceGroups == null ? null : <int>[];
    final vmap = Int32List(n);
    for (var v = 0; v < n; v++) {
      vmap[v] = builder.addVertex(mesh.vx(v), mesh.vy(v), mesh.vz(v));
    }
    // Offset copy of every vertex used by the selection.
    final raised = Int32List(n);
    for (var v = 0; v < n; v++) {
      raised[v] = -1;
    }
    for (var f = 0; f < mesh.faceCount; f++) {
      if (faceMask[f] == 0) continue;
      for (var k = 0; k < 3; k++) {
        final v = mesh.indices[f * 3 + k];
        if (raised[v] >= 0) continue;
        raised[v] = builder.addVertex(
          mesh.vx(v) + rx * distance,
          mesh.vy(v) + ry * distance,
          mesh.vz(v) + rz * distance,
        );
        colors?.addAll(mesh.vertexColors!.sublist(v * 3, v * 3 + 3));
      }
    }

    // Unselected faces stay.
    for (var f = 0; f < mesh.faceCount; f++) {
      if (faceMask[f] != 0) continue;
      builder.addTriangle(vmap[mesh.indices[f * 3]],
          vmap[mesh.indices[f * 3 + 1]], vmap[mesh.indices[f * 3 + 2]]);
      groups?.add(mesh.faceGroups![f]);
    }
    // Raised top.
    for (var f = 0; f < mesh.faceCount; f++) {
      if (faceMask[f] == 0) continue;
      builder.addTriangle(raised[mesh.indices[f * 3]],
          raised[mesh.indices[f * 3 + 1]], raised[mesh.indices[f * 3 + 2]]);
      groups?.add(mesh.faceGroups![f]);
    }
    // Skirt along the selection boundary.
    var walls = 0;
    for (var f = 0; f < mesh.faceCount; f++) {
      if (faceMask[f] == 0) continue;
      for (var k = 0; k < 3; k++) {
        final a = mesh.indices[f * 3 + k];
        final b = mesh.indices[f * 3 + (k + 1) % 3];
        final inc = topo.edgeFaces[topo.edgeKey(a, b)] ?? const <int>[];
        var neighbours = 0;
        for (final g in inc) {
          if (faceMask[g] != 0) neighbours++;
        }
        if (neighbours != 1) continue;
        // Boundary edge of the selected region: connect original to raised.
        final a2 = raised[a], b2 = raised[b];
        if (a2 < 0 || b2 < 0) continue;
        builder.addTriangle(vmap[a], vmap[b], b2);
        builder.addTriangle(vmap[a], b2, a2);
        groups?.addAll([mesh.faceGroups![f], mesh.faceGroups![f]]);
        walls++;
      }
    }
    final out = builder.build()
      ..faceGroups = groups == null ? null : Uint16List.fromList(groups)
      ..vertexColors = colors == null ? null : Float32List.fromList(colors);
    out.removeDegenerateFaces(minArea: 0);
    if (walls > 0 && smoothBoundary && smoothIterations > 0) {
      _relaxBoundary(out, raised, smoothIterations);
    }
    out.compact();
    return out;
  }

  static void _relaxBoundary(TriMesh mesh, Int32List raised, int iterations) {
    final topo = MeshTopology(mesh);
    final movable = <int>{};
    for (final v in raised) {
      if (v >= 0) movable.add(v);
    }
    for (var it = 0; it < iterations; it++) {
      final next = Float32List.fromList(mesh.positions);
      for (final v in movable) {
        final nb = topo.neighborsOfVertex(v);
        if (nb.length < 3) continue;
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

/// Splits a multi-shell mesh into one mesh per connected component.
///
/// Meshmixer exposes this as "Separate Shells" (SeparateShellsTool.cpp).
class ShellSeparator {
  static List<TriMesh> separate(TriMesh mesh) {
    final topo = MeshTopology(mesh);
    final (faceComp, count) = topo.components();
    if (count <= 1) return <TriMesh>[mesh];
    final out = <TriMesh>[
      for (var c = 0; c < count; c++)
        mesh.extractFaces([
          for (var f = 0; f < mesh.faceCount; f++)
            if (faceComp[f] == c) f,
        ]),
    ];
    out.sort((a, b) => b.surfaceArea().compareTo(a.surfaceArea()));
    return out;
  }
}
