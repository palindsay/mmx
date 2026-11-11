import 'dart:io';

// Run from the repository root after generating kernel coverage/lcov.info.
void main(List<String> args) {
  final source = File(
    args.isEmpty ? 'packages/mmx_core/coverage/lcov.info' : args.single,
  ).readAsStringSync();
  const required = [
    'io/project.dart',
    'io/atomic_file.dart',
    'io/zip.dart',
    'io/threemf.dart',
    'io/polygon_triangulation.dart',
    'io/obj.dart',
    'io/ply.dart',
    'io/stl.dart',
    'io/mesh_io.dart',
    'io/asset_path.dart',
    'io/texture.dart',
    'io/mtl.dart',
    'io/threemf_materials.dart',
    'mesh/material.dart',
    'scene/document.dart',
    'analysis/wall_thickness.dart',
    'solid/marching_tetrahedra.dart',
    'mesh/attributes.dart',
    'mesh/limits.dart',
    'geom/planar_region.dart',
    'tools/selection_edit.dart',
    'scan/workflow.dart',
    'scan/recipe.dart',
    'scan/provenance.dart',
  ];
  final found = <String>{};
  for (final record in source.split('end_of_record')) {
    final lines = record.split('\n');
    final path = lines
        .where((l) => l.startsWith('SF:'))
        .firstOrNull
        ?.replaceAll('\\', '/');
    if (path == null) continue;
    final name = required.where((p) => path.endsWith(p)).firstOrNull;
    if (name == null) continue;
    found.add(name);
    final hits = lines
        .where((l) => l.startsWith('DA:'))
        .map((l) => int.parse(l.split(',')[1]))
        .toList();
    final ratio = hits.isEmpty
        ? 0.0
        : hits.where((n) => n > 0).length / hits.length;
    stdout.writeln('$name: ${(ratio * 100).toStringAsFixed(1)}%');
    if (ratio <= .8) exitCode = 1;
  }
  if (found.length != required.length) {
    stderr.writeln(
      'Missing coverage records: ${required.where((p) => !found.contains(p)).join(', ')}',
    );
    exitCode = 1;
  }
}
