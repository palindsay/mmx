# Editing materials in Studio

In **Navigate** or **Modify**, expand **Material and texture** in the properties
panel. Enter Red, Green, Blue, and Alpha values from 0 to 1. Choose a PNG or JPEG
texture, a UV mapping, and whether texture edges clamp or repeat. These are draft
settings: **Apply material** updates the selected object in one undo step.
Selecting or canceling a file alone does not change the scene.

Apply assigns one diffuse material to every face. Imported multi-material
assignments are replaced only when Apply is pressed. Existing vertex colors
remain and also tint the result. To remove only the texture, select **Remove
texture**, then Apply. **Remove materials and UVs** is a separate undoable action
that preserves geometry, face groups, vertex colors, object transforms and pivots.

**Keep existing UVs** preserves imported texture seams. Planar X/Y/Z projects the
mesh onto the perpendicular YZ/XZ/XY plane and normalizes coordinates to 0–1.
Choosing a texture on an object without UVs stages Planar Y by default; change the
axis before Apply if needed. Planar mapping can overlap opposite faces and is not
an atlas unwrap. A texture without UV coordinates is rejected with an error.

Textures are decoded in a cancellable worker, with a 16 MiB encoded limit and
maximum dimensions of 4096×4096. Animated/malformed images and nonfinite color
values are rejected. Failed or canceled operations retain the prior mesh and
history; the panel keeps a failed draft available for correction.

The current viewport supports diffuse color/texture and **alpha cutout**: alpha
below 0.5 is transparent; other samples are opaque. Original alpha values and
encoded texture bytes are retained in `.mmx` projects. This is not translucent
blending or a PBR material editor.

Save `.mmx` to retain all supported scene attributes. OBJ exports retain supported
materials and textures as companion files. 3MF supports compatible diffuse
materials, with unsupported combinations rejected explicitly. Geometry-only
formats require removing materials/UVs first; export does not silently discard
them. The renderer selector in View properties exposes CPU/automatic/GPU choices,
and the viewport reports the backend actually used.

State/widget tests live in `apps/mmx_studio/test/material_panel_test.dart`; native
filesystem, rendering, UI application, undo and project round trips are exercised
by `apps/mmx_studio/integration_test/material_workflow_test.dart`.
