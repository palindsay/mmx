# Transform controls

Studio's **Navigate** and **Modify** tools expose **Transform** properties.
Choose Move, Rotate, Scale, or Move pivot in those properties or the viewport's
Gizmo selector. Red, green, and blue handles correspond to X, Y, and Z.

- **World axes** stay aligned with the scene. **Local axes** follow the selected
  object's transformed basis, including nonuniform scales and reflections.
  Movement distances are millimeters in either space.
- **Move** drags along an axis. **Rotate** drags a colored ring around the pivot;
  continuous drags can make multiple turns. A view-facing axis still has a
  selectable ring. Numeric angle signs follow the existing `rotation4` convention.
- **Scale / Selected axis** scales only that axis. Local scaling changes one
  object basis column; world scaling changes a world direction and can introduce
  shear on a rotated object. **Uniform** retains proportional scaling: drag a
  handle right/up to enlarge, left/down to shrink. Factors are limited to
  0.01–100 per edit.
- **Move pivot** changes the pivot's object-local position without changing mesh
  geometry or its transform. Rotation and scaling keep that pivot fixed in
  world space. Without an explicit pivot, the mesh bounds' local center is used.

Enable **Snap** and enter the relevant increment: millimeters, degrees, or scale
percentage points. Snapping is relative to the beginning of the drag or numeric
edit. For example, 10% scale snapping rounds factor 1.26 to 1.3, not 1.2.

For keyboard input, choose an axis and enter Distance, Angle, or Scale factor.
Press Enter in the amount field, or Tab to **Apply transform** and activate it.
Numeric edits use the same coordinate space, snapping, pivot, and undo behavior
as dragging. Invalid/nonfinite input is rejected. **Escape** or pointer
cancellation restores a drag's starting state. A completed drag or numeric edit
creates one undo step; snapping back to the starting value creates none.

Operation, coordinate-space, and snap controls lock during a drag. Settings are
session controls; saved `.mmx` projects retain the resulting transforms and
local pivots. Singular transforms reject pivot edits rather than storing invalid
coordinates. Nearly edge-on rotation planes use screen-angle dragging when a
stable ray/plane intersection is unavailable; numeric input remains available.

Verification is in `apps/mmx_studio/test/advanced_manipulator_test.dart` and
`apps/mmx_studio/integration_test/advanced_manipulator_test.dart`. Tests cover
rotated/nonuniform and sheared transforms, pivot invariance, relative snapping,
ring picking/multiple turns, keyboard application, independent pointer ownership,
Escape/cancel rollback, one-step history, preview-failure lock release, and native
project save/reopen.
