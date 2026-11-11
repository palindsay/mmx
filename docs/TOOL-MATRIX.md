# Tool and action coverage

This matrix maps every named tool recovered from the shipped Meshmixer 3.5.0
binary to the mmx implementation and its user-facing exposure. Status values:

- **implemented** - kernel and Studio action exist; tests cover the main path.
- **kernel only** - the operator exists in `mmx_core`/CLI but has no Studio UI.
- **partial** - a usable implementation exists, but a documented mode or
  parameter is missing.
- **out of scope** - deliberately not reproduced; the reason is recorded.

Evidence is from `docs/REVERSE-ENGINEERING.md` (tool help XML, Qt meta-object
strings and RTTI), `docs/METHODS.md` and `docs/RTTI.md`.

## Named tools

| Tool | Kernel | Studio | Status | Notes |
|---|---|---|---|---|
| AlignTool | `tools/align.dart` ICP | Align to target | implemented | Rigid ICP; no manual point-pair alignment UI. |
| CloseCracksTool | `repair/bridge.dart` | Stitch cracks | implemented | Nearest-boundary stitching. |
| ConvertToPartTool | `ComplexTools.extract` | Extract | implemented | Extracts selected faces into a new object. |
| ConvertToSolidTool | `ComplexTools.makeSolidPart` | Make Part | implemented | Solidifies the selected region. |
| ConvertToStampTool | `tools/stamp.dart` | Stamp | partial | Procedural height fields; image-to-stamp conversion is not exposed. |
| DeformTool | `tools/deform.dart` | none | kernel only | Soft move/bend; no manipulator UI yet. |
| DropTool | `tools/modify.dart` | Drop to bed | implemented | Places the object on the bed. |
| DuplicateTool | `scene/document.dart` | Duplicate | implemented | Copies the selected object. |
| EditPlaneCutTool | `tools/plane_cut.dart` | Plane Cut / Scan trim | partial | Arbitrary cuts, slice groups and cavity-preserving planar caps; alternative fill/attach semantics are not fully reproduced. |
| ExtractTool | `ComplexTools.extract` | Extract | implemented | Same path as ConvertToPart. |
| ExtrudeTool | `tools/edits.dart` | Extrude | implemented | Selection extrusion with skirt. |
| FaceSelectionTool | `mesh/topology.dart`, selection sets | Select | implemented | Brush selection, expand/contract. |
| FaceTransformTool | `tools/deform.dart` | none | partial | Kernel transforms exist; no dedicated face-transform panel. |
| FaceVariationalMoveTool | `tools/deform.dart` | none | kernel only | Soft move/bend approximation. |
| FitPrimitiveTool | `tools/modify.dart` | Replace with primitive | implemented | Box/cylinder/sphere fitting. |
| FlipNormalsTool | `tools/modify.dart` | Flip normals | implemented | Whole mesh or selection. |
| GenerateFaceGroupsTool | `mesh/topology.dart` | Face groups | implemented | Angle-threshold grouping. |
| HandleTool | none | none | out of scope | Curve/rod handles are not needed by the current workflows. |
| InspectorTool | `repair/inspector.dart`, `scan/workflow.dart` | Inspector / Scan to print | implemented | Selectable boundaries, non-manifold connectivity, intersections and fragments; floating-point intersection checks have an explicit reporting limit. |
| JoinTool | `ComplexTools.join` | Combine all | implemented | Joins visible editable objects; hidden or protected originals are excluded. |
| MakePartTool | `ComplexTools.extract` | Make Part | implemented | Extract plus optional solidification. |
| MakePatternTool | `tools/modify.dart` | Make pattern | implemented | Grid array; other pattern modes are partial. |
| MakeSolidTool | `solid/solidifier.dart` | Make Solid | implemented | Blocky/fast/accurate and offsets; bounded directional minimum-wall verification in Accurate/Blocky. |
| MeasuringTool | `tools/modify.dart` | Measure | implemented | Dimensions, area, volume, shells. |
| MirrorTool | `tools/edits.dart` | Mirror | implemented | Seam welding. |
| OverhangTool | `analysis/analysis.dart` | Analysis overlay | implemented | Angle-based heat map. |
| ReduceTool | `remesh/decimate.dart` | Reduce / Scan preview | partial | Percentage controls, CLI face targets/uniform mode, regional boundary pinning and sampled physical deviation checks; not all recovered modes have Studio controls. |
| RemeshTool | `remesh/isotropic.dart` | Remesh / Scan preview | partial | Isotropic, adaptive and group-aware kernel paths; selected-patch boundaries are pinned. No faithful transition-width control. |
| ReplaceTool | `tools/modify.dart` | Replace with primitive | implemented | Fit primitive and replace. |
| SelectPlaneCutTool | `tools/plane_cut.dart` | Plane Cut | partial | Selection-limited cut is not exposed in the panel. |
| SmoothBoundaryTool | `repair/holes.dart` | none | partial | Hole-fill relaxation exists; no standalone boundary smooth action. |
| SmoothingBrushTool | `tools/sculpt.dart` | Sculpt (smooth) | implemented | Taubin-style brush. |
| SmoothTool | `tools/modify.dart`, `scan/workflow.dart` | Smooth / Scan denoise | implemented | Whole-mesh/selected smoothing; scan denoise additionally bounds physical displacement and pins boundaries/creases. |
| SoftTransformTool | `tools/deform.dart` | none | kernel only | Soft move/bend. |
| StabilityTool | `analysis/analysis.dart` | Analysis overlay | implemented | COM, support polygon and tip angle. |
| StampTool | `tools/stamp.dart` | Stamp | partial | Analytic height fields; image stamps are not decoded. |
| StitchBoundaryTool | `repair/bridge.dart` | Stitch cracks | implemented | Boundary-loop bridge/stitch. |
| StrengthTool | none | none | out of scope | Material-strength simulation is not part of the core workflow. |
| SurfaceBrushTool | `tools/sculpt.dart` | Sculpt | implemented | Draw/inflate/flatten/pinch/crease/twist/move. |
| TransformTool | `scene/document.dart` transform | Numeric controls and viewport handles | implemented | World/local axes, axis/uniform scale, snapping, numeric entry and pivot-safe single-entry undo. |
| UnitsTool | import scaling, 3MF unit conversion | Import units selector | implemented | Scene units are millimeters; unitless formats offer explicit conversion. |
| VolumeBrushTool | `tools/sculpt.dart` | Sculpt | partial | Volume-like inflate/draw; no separate volume brush UI. |

## Recovered action handlers

| Action | Kernel | Studio | Status |
|---|---|---|---|
| Meshmix | `ComplexTools`/primitives | none | partial (library browser not reproduced) |
| Import | `io/*` | Import | implemented |
| Select | selection sets | Select | implemented |
| Sculpt | `tools/sculpt.dart` | Sculpt | implemented |
| Stamp | `tools/stamp.dart` | Stamp | partial |
| Edits | `tools/*` | Modify | implemented |
| Analysis | `analysis/*` | Analysis | implemented |
| Shaders | CPU rasterizer and native wgpu | Material/texture panel and viewport | partial (diffuse materials, UV textures and alpha cutout; no PBR/sorted translucency) |
| SeparateShells | `tools/edits.dart` | Separate shells | implemented |
| Export | `io/*` | Export | implemented |
| Print | `fab/*` | Print | implemented |
| Mirror | `tools/edits.dart` | Mirror | implemented |
| Duplicate | document | Duplicate | implemented |
| Transform | document transform | Numeric controls and viewport handles | implemented |
| CreatePivot | `tools/pivot.dart` | Pivot and viewport handle | implemented (local pivot persists in projects) |
| Align / AlignToTarget | `tools/align.dart` | Align to target | implemented |
| PlaneCut | `tools/plane_cut.dart` | Plane Cut | implemented |
| Combine | `ComplexTools.join` | Combine all | implemented |
| Union / Intersection / Difference | `solid/mesh_boolean.dart` | Project → Boolean | implemented (precise/grid, explicit operands and fallback reporting) |
| WeldCracks | `repair/bridge.dart` | Stitch cracks | implemented |
| MakeSolid | `solid/solidifier.dart` | Make Solid | implemented |
| CreateInteriorSurface | `solid/solidifier.dart` | Hollow | partial |
| ExtractExteriorSurface | `ComplexTools.extract` | Extract | partial |
| SplitNonManifoldSurface | `repair/inspector.dart` | Auto repair / Scan connectivity preview | implemented (attribute-preserving vertex fan splits; introduced boundaries require review) |
| MakePattern | `tools/modify.dart` | Make pattern | implemented |
| Hollow | `solid/solidifier.dart` | Hollow | implemented |
| Unwrap | `tools/unwrap.dart` | Material planar mapping | implemented (planar corner UVs persisted in projects and supported exports) |
| VariationalRemesh | `remesh/isotropic.dart` | Remesh (group-aware) | implemented |

## Additional mmx scan workflow

These are **observed mmx capabilities**, not claims of Autodesk algorithm parity:

| Workflow | Exposure and limits |
|---|---|
| Fresh project | Empty startup, New Project shortcut, Save/Discard/Cancel and recovery-safe replacement. |
| Reversible cleanup | Fragment/denoise/hole/bridge/trim/reduce/remesh previews, original comparison, Apply/Cancel and undo. |
| Traceable edits | Protected original, schema 3 history, geometry/attribute hashes and inferred-patch groups; whole-mesh recipe export checks continuity. |
| Printer preflight | FDM/resin assumptions, configured bed bounds, sampled wall/overhang findings and reports; drainage and print outcomes remain unverified. |
| Batch reuse | Versioned CLI recipes, per-input failure isolation, report export and overwrite refusal. |

See the [Studio guide](../apps/mmx_studio/README.md#scan-to-print),
[recipe contracts](CLI.md#scan-to-print-workflow) and
[commercial acceptance requirements](PRODUCTION-READINESS.md#commercial-acceptance-work).

## Remaining parity gaps

1. External Meshmixer fidelity comparisons; analytical empty/disjoint boolean cases now pass.
2. Face-deformation manipulators beyond the implemented object transforms.
3. Image stamps and the stamp/texture semantics.
4. Advanced UV seam authoring, material layers and proprietary `.mix` shader semantics.
5. Selection-limited plane cuts and the remaining plane-cut attach modes.
6. Face transform / variational move UI.
