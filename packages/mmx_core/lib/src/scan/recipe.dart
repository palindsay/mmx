import 'dart:typed_data';

import '../mesh/tri_mesh.dart';
import '../mesh/topology.dart';
import '../repair/bridge.dart';
import '../repair/holes.dart';
import '../repair/inspector.dart';
import '../repair/weld.dart';
import '../remesh/decimate.dart';
import '../remesh/isotropic.dart';
import '../tools/plane_cut.dart';
import '../tools/selection_edit.dart';
import 'workflow.dart';

/// Versioned, deterministic recipe steps shared by Studio previews and the CLI.
/// Each parameter is in physical millimeters unless its name states otherwise.
class ScanStep {
  final String operation;
  final Map<String, Object?> parameters;
  ScanStep(this.operation, [Map<String, Object?> parameters = const {}])
      : parameters = Map.unmodifiable(parameters) {
    final allowed = _keys[operation];
    if (allowed == null || parameters.keys.any((k) => !allowed.contains(k))) {
      throw ArgumentError('Unknown scan operation or parameter');
    }
    for (final value in parameters.values) {
      if (value is! num || !value.isFinite) {
        throw ArgumentError('Scan parameters must be finite numbers');
      }
    }
  }
  static const _keys = <String, Set<String>>{
    'repair': {'weldMm'},
    'fragments': {'areaMm2'},
    'denoise': {'displacementMm', 'iterations', 'creaseDegrees'},
    'reduce': {'keepFraction', 'deviationMm'},
    'remesh': {'edgeMm', 'deviationMm'},
    'fillHole': {'loop', 'smooth'},
    'bridgeHoles': {'first', 'second'},
    'trim': {'x', 'y', 'z', 'nx', 'ny', 'nz', 'keepPositive'},
  };
  double number(String key, double fallback) =>
      (parameters[key] as num?)?.toDouble() ?? fallback;
  int integer(String key, int fallback) {
    final n = number(key, fallback.toDouble());
    if (n != n.truncateToDouble()) {
      throw ArgumentError('$key must be an integer');
    }
    return n.toInt();
  }

  Map<String, Object?> toJson() =>
      {'operation': operation, 'parameters': parameters};
  factory ScanStep.fromJson(Map<String, dynamic> value) {
    if (value.keys.any((k) => k != 'operation' && k != 'parameters') ||
        value['operation'] is! String ||
        (value['parameters'] != null &&
            value['parameters'] is! Map<String, dynamic>)) {
      throw const FormatException('Invalid recipe step');
    }
    return ScanStep(value['operation'] as String,
        Map<String, Object?>.from(value['parameters'] ?? {}));
  }
}

class ScanEditResult {
  final TriMesh mesh;
  final SurfaceDeviation deviation;
  final String note;
  final int? inferredGroup;
  ScanEditResult(this.mesh, this.deviation, this.note, {this.inferredGroup});
}

class ScanRecipe {
  final List<ScanStep> steps;
  ScanRecipe(List<ScanStep> steps) : steps = List.unmodifiable(steps) {
    if (steps.isEmpty || steps.length > 100) {
      throw ArgumentError('A recipe needs 1–100 steps');
    }
  }
  factory ScanRecipe.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['units'] != 'mm' ||
        value['steps'] is! List ||
        (value['steps'] as List).any((step) => step is! Map<String, dynamic>) ||
        value.keys.any((k) => !{'version', 'units', 'steps'}.contains(k))) {
      throw const FormatException('Unsupported scan recipe');
    }
    return ScanRecipe([
      for (final step in value['steps'] as List)
        ScanStep.fromJson(Map<String, dynamic>.from(step as Map))
    ]);
  }
  Map<String, Object?> toJson() => {
        'version': 1,
        'units': 'mm',
        'steps': steps.map((s) => s.toJson()).toList()
      };

  static ScanEditResult apply(TriMesh input, ScanStep step,
      {Uint8List? selection}) {
    TriMesh output;
    var note = '';
    int? inferred;
    switch (step.operation) {
      case 'fragments':
        final remove = ScanWorkflow.fragments(input,
            maximumArea: step.number('areaMm2', 1), protectedFaces: selection);
        output = input.extractFaces([
          for (var f = 0; f < input.faceCount; f++)
            if (remove[f] == 0) f
        ]);
        note =
            'Removed ${input.faceCount - output.faceCount} faces in small components; selected components protected.';
      case 'denoise':
        output = ScanWorkflow.denoise(input,
            maximumDisplacement: step.number('displacementMm', .1),
            iterations: step.integer('iterations', 5),
            creaseAngle: step.number('creaseDegrees', 45),
            faceMask: selection);
        note =
            'Boundaries and creases protected; original-relative displacement bounded.';
      case 'reduce':
        final fraction = step.number('keepFraction', .5);
        if (fraction <= 0 || fraction > 1) {
          throw ArgumentError('Keep fraction must be in (0,1]');
        }
        TriMesh edit(TriMesh patch) =>
            Decimator.reduce(patch, percentage: fraction);
        output = selection == null
            ? edit(input)
            : editSelection(input, selection, edit);
      case 'remesh':
        TriMesh edit(TriMesh patch) => IsotropicRemesher.remesh(patch,
            targetEdgeLength: step.number('edgeMm', 1),
            preserveSharp: true,
            preserveGroupBoundaries: true,
            iterations: 5);
        output = selection == null
            ? edit(input)
            : editSelection(input, selection, edit);
      case 'repair':
        final tolerance = step.number('weldMm', .001);
        if (tolerance < 0) {
          throw ArgumentError('Weld tolerance must be nonnegative');
        }
        output = input.clone();
        if (tolerance > 0) {
          output = Weld.weldVertices(output, tolerance: tolerance);
        }
        output.removeDegenerateFaces(minArea: 0);
        Weld.removeDuplicateFaces(output);
        output = MeshInspector.splitNonManifold(output);
        output.compact();
        note =
            'Welded and split connectivity. Open boundaries and intersections require review; holes were preserved.';
      case 'fillHole':
        final loop = step.integer('loop', 0),
            smooth = step.integer('smooth', 0);
        if (smooth != 0 && smooth != 1) {
          throw ArgumentError('smooth must be 0 or 1');
        }
        output = HoleFiller.fill(input,
            loopIndices: {loop},
            requireAll: true,
            mode: smooth == 1 ? HoleFillMode.smooth : HoleFillMode.flatMinimal);
        note =
            'Inferred patch; measured scan geometry around its boundary is unchanged.';
      case 'bridgeHoles':
        final loops = MeshTopology(input).boundaryLoops();
        final first = step.integer('first', 0),
            second = step.integer('second', 1);
        if (first < 0 ||
            second < 0 ||
            first >= loops.length ||
            second >= loops.length ||
            first == second) {
          throw ArgumentError('Choose two distinct boundary loops');
        }
        output = Bridge.bridgeLoops(input, loops[first], loops[second]);
        if (MeshTopology(output).nonManifoldEdges().isNotEmpty) {
          throw StateError('Bridge creates non-manifold geometry');
        }
        note =
            'Inferred bridge; inspect shape and intersections before applying.';
      case 'trim':
        final keep = step.integer('keepPositive', 1);
        if (keep != 0 && keep != 1) {
          throw ArgumentError('keepPositive must be 0 or 1');
        }
        output = PlaneCut.cut(input,
            point: [
              step.number('x', 0),
              step.number('y', 0),
              step.number('z', 0)
            ],
            normal: [
              step.number('nx', 0),
              step.number('ny', 1),
              step.number('nz', 0)
            ],
            keepPositive: keep == 1);
        note =
            'Cut plane capped with cavities preserved. Use Drop to bed after orienting the cut surface.';
      default:
        throw ArgumentError('Unsupported scan operation');
    }
    if (output.validate().isNotEmpty || output.faceCount == 0) {
      throw StateError('Cleanup would leave no valid surface');
    }
    if ({'fillHole', 'bridgeHoles'}.contains(step.operation)) {
      var group = 0;
      for (final g in input.faceGroups ?? Uint16List(0)) {
        if (g > group) group = g;
      }
      if (group >= 65535) throw StateError('No free group for inferred patch');
      inferred = group + 1;
      output.faceGroups = Uint16List.fromList([
        ...(input.faceGroups ?? Uint16List(input.faceCount)),
        ...List<int>.filled(output.faceCount - input.faceCount, inferred)
      ]);
    }
    final deviation = SurfaceDeviation.measure(input, output);
    if (step.operation == 'reduce' || step.operation == 'remesh') {
      final budget = step.number('deviationMm', .2);
      if (budget <= 0) throw ArgumentError('Deviation budget must be positive');
      if (deviation.maximum > budget) {
        throw StateError(
            'Sampled deviation ${deviation.maximum.toStringAsFixed(4)} mm exceeds $budget mm; use a less aggressive setting');
      }
      note =
          'Bidirectional sampled deviation within $budget mm; this is not a certified global bound.';
    }
    return ScanEditResult(output, deviation, note, inferredGroup: inferred);
  }
}
