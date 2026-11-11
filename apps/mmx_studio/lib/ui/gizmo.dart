import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mmx_core/mmx_core.dart';

import '../state/manipulator.dart';
import '../state/studio_state.dart';

/// Projection shared by painting, hit testing and screen-to-world dragging.
class GizmoProjection {
  final Offset origin;
  final List<Offset?> handles;
  final double worldLength;
  final ManipulatorScaleMode scaleMode;
  final ManipulatorMode mode;
  final List<List<Offset?>> rotationRings;
  final List<List<double>> directions;
  final List<double> worldOrigin;
  final Camera camera;
  final Size size;
  const GizmoProjection(
    this.origin,
    this.handles,
    this.worldLength,
    this.scaleMode,
    this.mode,
    this.rotationRings,
    this.directions,
    this.worldOrigin,
    this.camera,
    this.size,
  );

  static GizmoProjection? forState(StudioState state, Size size) {
    final object = state.selected;
    if (object == null || size.width <= 0 || size.height <= 0) return null;
    final world = objectPivotWorld(object);
    late List<List<double>> directions;
    try {
      directions = manipulatorDirections(object, state.manipulatorSpace);
    } on FormatException {
      return null;
    }
    final matrix = state.camera.viewProjection(size.width / size.height);
    Offset? project(List<double> p) {
      final w =
          matrix[3] * p[0] + matrix[7] * p[1] + matrix[11] * p[2] + matrix[15];
      if (!w.isFinite || w <= state.camera.near) return null;
      final x =
          (matrix[0] * p[0] +
              matrix[4] * p[1] +
              matrix[8] * p[2] +
              matrix[12]) /
          w;
      final y =
          (matrix[1] * p[0] +
              matrix[5] * p[1] +
              matrix[9] * p[2] +
              matrix[13]) /
          w;
      return Offset((x + 1) * size.width / 2, (1 - y) * size.height / 2);
    }

    final origin = project(world);
    if (origin == null) return null;
    final eye = state.camera.position();
    final distance = math.sqrt(
      List.generate(
        3,
        (i) => math.pow(eye[i] - world[i], 2),
      ).reduce((a, b) => a + b),
    );
    final length =
        distance *
        math.tan(state.camera.fovDegrees * math.pi / 360) *
        144 /
        size.height;
    final handles = [
      for (var axis = 0; axis < 3; axis++)
        project([
          for (var i = 0; i < 3; i++) world[i] + directions[axis][i] * length,
        ]),
    ];
    final rings = <List<Offset?>>[];
    if (state.manipulatorMode == ManipulatorMode.rotate) {
      for (final normal in directions) {
        final reference = normal[1].abs() < .9
            ? [0.0, 1.0, 0.0]
            : [1.0, 0.0, 0.0];
        final cross = [
          normal[1] * reference[2] - normal[2] * reference[1],
          normal[2] * reference[0] - normal[0] * reference[2],
          normal[0] * reference[1] - normal[1] * reference[0],
        ];
        final norm = math.sqrt(
          cross.fold<double>(0, (sum, value) => sum + value * value),
        );
        final u = cross.map((value) => value / norm).toList();
        final v = [
          normal[1] * u[2] - normal[2] * u[1],
          normal[2] * u[0] - normal[0] * u[2],
          normal[0] * u[1] - normal[1] * u[0],
        ];
        rings.add([
          for (var sample = 0; sample <= 64; sample++)
            project([
              for (var i = 0; i < 3; i++)
                world[i] +
                    length *
                        (u[i] * math.cos(sample * math.pi / 32) +
                            v[i] * math.sin(sample * math.pi / 32)),
            ]),
        ]);
      }
    }
    return GizmoProjection(
      origin,
      handles,
      length,
      state.manipulatorScaleMode,
      state.manipulatorMode,
      rings,
      directions,
      world,
      state.camera.clone(),
      size,
    );
  }

  int? hitTest(Offset position) {
    var best = 12.0;
    int? axis;
    if (mode == ManipulatorMode.rotate) {
      for (var i = 0; i < rotationRings.length; i++) {
        final ring = rotationRings[i];
        for (var j = 1; j < ring.length; j++) {
          final a = ring[j - 1], b = ring[j];
          if (a == null || b == null) continue;
          final segment = b - a;
          if (segment.distanceSquared < 1e-8) continue;
          final delta = position - a;
          final t =
              ((delta.dx * segment.dx + delta.dy * segment.dy) /
                      segment.distanceSquared)
                  .clamp(0.0, 1.0);
          final distance = (position - (a + segment * t)).distance;
          if (distance < best) {
            best = distance;
            axis = i;
          }
        }
      }
      return axis;
    }
    for (var i = 0; i < 3; i++) {
      final handle = handles[i];
      if (handle == null || (handle - origin).distance < 18) continue;
      final v = handle - origin, q = position - origin;
      final t = ((q.dx * v.dx + q.dy * v.dy) / v.distanceSquared).clamp(
        .25,
        1.0,
      );
      final distance = (position - (origin + v * t)).distance;
      if (distance < best) {
        best = distance;
        axis = i;
      }
    }
    return axis;
  }

  double dragAmount(
    ManipulatorMode mode,
    int axis,
    Offset start,
    Offset current,
  ) {
    if (mode == ManipulatorMode.rotate) {
      final normal = directions[axis];
      List<double>? planePoint(Offset screen) {
        final ray = camera.screenToRay(
          screen.dx,
          screen.dy,
          size.width,
          size.height,
        );
        double dot(List<double> a, List<double> b) =>
            List.generate(3, (i) => a[i] * b[i]).reduce((a, b) => a + b);
        final denominator = dot(ray.direction, normal);
        if (denominator.abs() < 1e-6) return null;
        final distance =
            dot([
              for (var i = 0; i < 3; i++) worldOrigin[i] - ray.origin[i],
            ], normal) /
            denominator;
        if (!distance.isFinite || distance < 0) return null;
        final point = [
          for (var i = 0; i < 3; i++)
            ray.origin[i] + ray.direction[i] * distance - worldOrigin[i],
        ];
        return dot(point, point) < 1e-12 ? null : point;
      }

      final a = planePoint(start), b = planePoint(current);
      if (a != null && b != null) {
        final cross = [
          a[1] * b[2] - a[2] * b[1],
          a[2] * b[0] - a[0] * b[2],
          a[0] * b[1] - a[1] * b[0],
        ];
        return -math.atan2(
          List.generate(3, (i) => cross[i] * normal[i]).reduce((a, b) => a + b),
          List.generate(3, (i) => a[i] * b[i]).reduce((a, b) => a + b),
        );
      }
      // An edge-on rotation plane has no stable ray intersection. Use the
      // displayed angular gesture with a consistent camera-facing sign.
      final x = start - origin, y = current - origin, eye = camera.position();
      final facing = List.generate(
        3,
        (i) => normal[i] * (eye[i] - worldOrigin[i]),
      ).reduce((a, b) => a + b);
      return (facing >= 0 ? 1 : -1) *
          math.atan2(x.dx * y.dy - x.dy * y.dx, x.dx * y.dx + x.dy * y.dy);
    }
    if (mode == ManipulatorMode.scale) {
      final delta = current - start;
      if (scaleMode == ManipulatorScaleMode.uniform) {
        return math.exp((delta.dx - delta.dy) / 100);
      }
      final direction = handles[axis]! - origin;
      return math.exp(
        (delta.dx * direction.dx + delta.dy * direction.dy) /
            direction.distanceSquared,
      );
    }
    final v = handles[axis]! - origin, delta = current - start;
    return (delta.dx * v.dx + delta.dy * v.dy) /
        v.distanceSquared *
        worldLength;
  }
}

class GizmoPainter extends CustomPainter {
  final StudioState state;
  GizmoPainter(this.state) : super(repaint: state);
  @override
  void paint(Canvas canvas, Size size) {
    if (state.manipulatorMode == ManipulatorMode.none ||
        (state.tool != StudioTool.navigate &&
            state.tool != StudioTool.modify)) {
      return;
    }
    final p = GizmoProjection.forState(state, size);
    if (p == null) return;
    const colors = [
      Colors.redAccent,
      Colors.greenAccent,
      Colors.lightBlueAccent,
    ];
    if (state.manipulatorMode == ManipulatorMode.rotate) {
      for (var axis = 0; axis < p.rotationRings.length; axis++) {
        final ring = p.rotationRings[axis];
        final paint = Paint()
          ..color = colors[axis]
          ..strokeWidth = 2.5;
        for (var i = 1; i < ring.length; i++) {
          if (ring[i - 1] != null && ring[i] != null) {
            canvas.drawLine(ring[i - 1]!, ring[i]!, paint);
          }
        }
      }
      canvas.drawCircle(p.origin, 4, Paint()..color = Colors.white);
      return;
    }
    for (var i = 0; i < 3; i++) {
      final end = p.handles[i];
      if (end == null || (end - p.origin).distance < 18) continue;
      final paint = Paint()
        ..color = colors[i]
        ..strokeWidth = 3;
      canvas.drawLine(p.origin, end, paint);
      if (state.manipulatorMode == ManipulatorMode.rotate) {
        canvas.drawCircle(end, 9, paint..style = PaintingStyle.stroke);
      } else if (state.manipulatorMode == ManipulatorMode.scale) {
        canvas.drawRect(
          Rect.fromCenter(center: end, width: 13, height: 13),
          paint,
        );
      } else {
        canvas.drawCircle(end, 7, paint);
      }
      final label = TextPainter(
        text: TextSpan(
          text: ['X', 'Y', 'Z'][i],
          style: TextStyle(
            color: colors[i],
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, end + const Offset(10, -8));
    }
    canvas.drawCircle(p.origin, 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant GizmoPainter oldDelegate) => true;
}
