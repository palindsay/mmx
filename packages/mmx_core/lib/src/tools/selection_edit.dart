import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';

/// Edits only selected faces, joining the result at an unchanged boundary.
/// The edit must preserve every patch boundary vertex and edge. This contract
/// prevents accidental changes to the unselected surface or seam cracks.
TriMesh editSelection(
    TriMesh source, Uint8List mask, TriMesh Function(TriMesh patch) edit) {
  if (mask.length != source.faceCount) {
    throw ArgumentError('Selection size mismatch');
  }
  source.requireUntextured('Selection topology edit');
  final chosen = [
    for (var f = 0; f < source.faceCount; f++)
      if (mask[f] != 0) f
  ];
  if (chosen.isEmpty) return source.clone();
  final patch = source.extractFaces(chosen);
  final patchBoundary = MeshTopology(patch).boundaryEdges();
  String key(TriMesh m, int v) => '${m.vx(v)},${m.vy(v)},${m.vz(v)}';
  final originalIds = <String, int>{};
  final selectedVertices = {
    for (final f in chosen) ...source.indices.sublist(f * 3, f * 3 + 3)
  };
  final boundaryKeys = {
    for (final e in patchBoundary) ...[key(patch, e[0]), key(patch, e[1])]
  };
  for (final v in selectedVertices) {
    final k = key(source, v);
    if (!boundaryKeys.contains(k)) continue;
    if (originalIds.containsKey(k)) {
      throw StateError(
          'Selection boundary has coincident vertices; repair before editing');
    }
    originalIds[k] = v;
  }
  String edge(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
  final expected = {
    for (final e in patchBoundary) edge(key(patch, e[0]), key(patch, e[1]))
  };
  final changed = edit(patch);
  final actual = {
    for (final e in MeshTopology(changed).boundaryEdges())
      edge(key(changed, e[0]), key(changed, e[1]))
  };
  if (expected.length != actual.length || !actual.containsAll(expected)) {
    throw StateError('Selection edit changed its protected boundary');
  }
  final positions = <double>[...source.positions];
  final colors =
      source.vertexColors == null ? null : <double>[...source.vertexColors!];
  if (colors != null && changed.vertexColors == null) {
    throw StateError('Selection edit lost vertex colors');
  }
  final map = <int>[];
  for (var v = 0; v < changed.vertexCount; v++) {
    final shared = originalIds[key(changed, v)];
    if (shared != null) {
      map.add(shared);
      continue;
    }
    map.add(positions.length ~/ 3);
    positions.addAll([changed.vx(v), changed.vy(v), changed.vz(v)]);
    colors?.addAll(changed.vertexColors!.sublist(v * 3, v * 3 + 3));
  }
  final indices = <int>[];
  final groups = source.faceGroups == null ? null : <int>[];
  for (var f = 0; f < source.faceCount; f++) {
    if (mask[f] != 0) continue;
    indices.addAll(source.indices.sublist(f * 3, f * 3 + 3));
    groups?.add(source.faceGroups![f]);
  }
  indices.addAll(changed.indices.map((v) => map[v]));
  if (groups != null) {
    if (changed.faceGroups == null) {
      throw StateError('Selection edit lost face groups');
    }
    groups.addAll(changed.faceGroups!);
  }
  return TriMesh(Float32List.fromList(positions), Uint32List.fromList(indices),
      vertexColors: colors == null ? null : Float32List.fromList(colors),
      faceGroups: groups == null ? null : Uint16List.fromList(groups))
    ..compact();
}
