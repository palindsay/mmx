import 'dart:typed_data';
import 'dart:math' as math;

import 'package:mmx_core/mmx_core.dart';

enum ManipulatorMode { none, translate, rotate, scale, pivot }

enum ManipulatorSpace { world, local }

enum ManipulatorScaleMode { axis, uniform }

/// Snap increments are relative to the beginning of a gesture, not the origin.
/// Scale uses a factor increment: 0.1 means ten percentage points around 1.
class ManipulatorSnap {
  final bool enabled;
  final double translation;
  final double rotationDegrees;
  final double scale;
  const ManipulatorSnap({
    this.enabled = false,
    this.translation = 1,
    this.rotationDegrees = 15,
    this.scale = .1,
  });

  bool get isValid => [
    translation,
    rotationDegrees,
    scale,
  ].every((value) => value.isFinite && value > 0);

  double apply(ManipulatorMode mode, double amount) {
    if (!isValid || !amount.isFinite) {
      throw const FormatException(
        'Transform values and snap increments must be finite; increments must be positive',
      );
    }
    if (!enabled) return amount;
    final increment = switch (mode) {
      ManipulatorMode.rotate => rotationDegrees * (math.pi / 180),
      ManipulatorMode.scale => scale,
      _ => translation,
    };
    final neutral = mode == ManipulatorMode.scale ? 1.0 : 0.0;
    final steps = (amount - neutral) / increment;
    if (!steps.isFinite) {
      throw const FormatException('Snap increment is too small');
    }
    return neutral + steps.roundToDouble() * increment;
  }
}

List<double> objectPivotLocal(SceneObject object) {
  if (object.pivot != null) return List<double>.from(object.pivot!.position);
  final bounds = object.mesh.bounds();
  return bounds.isEmpty
      ? [0, 0, 0]
      : [
          (bounds.minX + bounds.maxX) / 2,
          (bounds.minY + bounds.maxY) / 2,
          (bounds.minZ + bounds.maxZ) / 2,
        ];
}

/// Local directions follow each object basis column, even after nonuniform
/// scaling. Translation distances stay in millimeters in either coordinate space.
List<List<double>> manipulatorDirections(
  SceneObject object,
  ManipulatorSpace space,
) {
  return List.generate(3, (axis) {
    if (space == ManipulatorSpace.world) {
      return List<double>.generate(3, (i) => i == axis ? 1 : 0);
    }
    final column = List<double>.generate(
      3,
      (i) => object.transform[axis * 4 + i],
    );
    final maximum = column.fold<double>(0, (a, b) => math.max(a, b.abs()));
    if (!maximum.isFinite || maximum == 0) {
      throw const FormatException(
        'Local axes require a nonzero finite object scale',
      );
    }
    final normalized = column.map((value) => value / maximum).toList();
    final length = math.sqrt(
      normalized.fold<double>(0, (sum, value) => sum + value * value),
    );
    return normalized.map((value) => value / length).toList();
  });
}

List<double> transformPoint(Float64List m, List<double> p) => [
  for (var i = 0; i < 3; i++)
    m[i] * p[0] + m[i + 4] * p[1] + m[i + 8] * p[2] + m[i + 12],
];

/// Inverse affine point transform, including nonuniform scaling and shear.
/// Reject singular transforms instead of silently corrupting a local pivot.
List<double> inverseTransformPoint(Float64List m, List<double> p) {
  // Normalize columns independently: legitimate nonuniform scales must not
  // be mistaken for singularity merely because one axis is much larger.
  final scales = [
    for (var col = 0; col < 3; col++)
      List.generate(3, (row) => m[col * 4 + row].abs()).reduce(math.max),
  ];
  if (scales.any((value) => value == 0 || !value.isFinite)) {
    throw const FormatException(
      'Cannot edit the pivot of a singular transform',
    );
  }
  final a = m[0] / scales[0], b = m[4] / scales[1], c = m[8] / scales[2];
  final d = m[1] / scales[0], e = m[5] / scales[1], f = m[9] / scales[2];
  final g = m[2] / scales[0], h = m[6] / scales[1], i = m[10] / scales[2];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (!det.isFinite || det.abs() <= 1e-12) {
    throw const FormatException(
      'Cannot edit the pivot of a singular transform',
    );
  }
  final q = [for (var axis = 0; axis < 3; axis++) p[axis] - m[12 + axis]];
  final magnitude = q.map((value) => value.abs()).reduce(math.max);
  if (!magnitude.isFinite) {
    throw const FormatException('Pivot exceeds the finite coordinate range');
  }
  if (magnitude == 0) return [0, 0, 0];
  final x = q[0] / magnitude, y = q[1] / magnitude, z = q[2] / magnitude;
  final values = [
    ((e * i - f * h) * x + (c * h - b * i) * y + (b * f - c * e) * z) / det,
    ((f * g - d * i) * x + (a * i - c * g) * y + (c * d - a * f) * z) / det,
    ((d * h - e * g) * x + (b * g - a * h) * y + (a * e - b * d) * z) / det,
  ];
  return [
    for (var axis = 0; axis < 3; axis++)
      values[axis] == 0 ? 0 : values[axis] * (magnitude / scales[axis]),
  ];
}

List<double> objectPivotWorld(SceneObject object) =>
    transformPoint(object.transform, objectPivotLocal(object));

class ManipulatorGesture {
  final SceneObject object;
  final ManipulatorMode mode;
  final int axis;
  final ManipulatorSpace space;
  final ManipulatorScaleMode scaleMode;
  final ManipulatorSnap snap;
  final Float64List originalTransform;
  final Pivot? originalPivot;
  final List<double> origin;
  final List<double> localOrigin;
  final List<double> direction;
  bool changed = false;

  ManipulatorGesture(
    this.object,
    this.mode,
    this.axis, {
    this.space = ManipulatorSpace.world,
    this.scaleMode = ManipulatorScaleMode.uniform,
    this.snap = const ManipulatorSnap(),
  }) : originalTransform = Float64List.fromList(object.transform),
       originalPivot = object.pivot == null
           ? null
           : Pivot(
               position: List<double>.from(object.pivot!.position),
               normal: List<double>.from(object.pivot!.normal),
             ),
       origin = objectPivotWorld(object),
       localOrigin = objectPivotLocal(object),
       direction = manipulatorDirections(object, space)[axis];

  /// Preview from the captured transform so event frequency cannot compound it.
  /// Local rotation is a rigid world rotation around the displayed local axis.
  /// Local axis scaling multiplies one object basis column; world axis scaling
  /// multiplies a world direction, which may introduce shear on rotated objects.
  double preview(double amount) {
    amount = snap.apply(mode, amount);
    if (mode == ManipulatorMode.scale) amount = amount.clamp(.01, 100);
    if (mode == ManipulatorMode.pivot) {
      final world = [
        for (var i = 0; i < 3; i++) origin[i] + direction[i] * amount,
      ];
      final local = inverseTransformPoint(originalTransform, world);
      if (local.any((value) => !value.isFinite)) {
        throw const FormatException(
          'Pivot exceeds the finite coordinate range',
        );
      }
      object.pivot = Pivot(
        position: local,
        normal: originalPivot?.normal ?? [0, 1, 0],
      );
    } else {
      final scale = identity4();
      for (var i = 0; i < 3; i++) {
        scale[i * 5] = scaleMode == ManipulatorScaleMode.uniform || i == axis
            ? amount
            : 1;
      }
      final delta = switch (mode) {
        ManipulatorMode.translate => translation4(
          direction[0] * amount,
          direction[1] * amount,
          direction[2] * amount,
        ),
        ManipulatorMode.rotate => rotation4(
          direction[0],
          direction[1],
          direction[2],
          amount,
        ),
        ManipulatorMode.scale => scale,
        _ => identity4(),
      };
      Float64List around(List<double> point) => multiply4(
        translation4(point[0], point[1], point[2]),
        multiply4(delta, translation4(-point[0], -point[1], -point[2])),
      );
      final next =
          mode == ManipulatorMode.scale && space == ManipulatorSpace.local
          ? multiply4(originalTransform, around(localOrigin))
          : multiply4(
              mode == ManipulatorMode.translate ? delta : around(origin),
              originalTransform,
            );
      if (next.any((value) => !value.isFinite)) {
        throw const FormatException(
          'Transform exceeds the finite coordinate range',
        );
      }
      object.transform = next;
    }
    changed = mode == ManipulatorMode.scale
        ? (amount - 1).abs() > 1e-9
        : amount.abs() > 1e-9;
    return amount;
  }

  void restore() {
    object.transform = Float64List.fromList(originalTransform);
    object.pivot = originalPivot;
  }
}

List<double> transformNormal(Float64List m, List<double> n) {
  final x =
      (m[5] * m[10] - m[9] * m[6]) * n[0] +
      (m[9] * m[2] - m[1] * m[10]) * n[1] +
      (m[1] * m[6] - m[5] * m[2]) * n[2];
  final y =
      (m[8] * m[6] - m[4] * m[10]) * n[0] +
      (m[0] * m[10] - m[8] * m[2]) * n[1] +
      (m[4] * m[2] - m[0] * m[6]) * n[2];
  final z =
      (m[4] * m[9] - m[8] * m[5]) * n[0] +
      (m[8] * m[1] - m[0] * m[9]) * n[1] +
      (m[0] * m[5] - m[4] * m[1]) * n[2];
  final det =
      m[0] * (m[5] * m[10] - m[9] * m[6]) +
      m[4] * (m[9] * m[2] - m[1] * m[10]) +
      m[8] * (m[1] * m[6] - m[5] * m[2]);
  final normal = [x, y, z];
  final length = math.sqrt(x * x + y * y + z * z);
  if (length == 0 || !length.isFinite) return [0, 1, 0];
  final sign = det < 0 ? -1 : 1;
  return normal.map((v) => sign * v / length).toList();
}
