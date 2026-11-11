# Verified directional wall clearance

## Supported contract

**Implemented and tested:** `WallThickness.certify(mesh, t)` checks continuous
**inward-normal opposing-surface clearance** on the final triangle mesh. For
every point of each source triangle, targets whose outward unit normals have
dot product below `-1e-4` with the source normal must be at least `t` away along
the inward normal. The cutoff is part of this metric: normals within about
0.00573 degrees of perpendicular are excluded. This practical exclusion avoids
classifying Float32 perturbations of rotated right-angle faces as opposing walls;
it intentionally does not measure those near-perpendicular features. Outside
gaps between separate objects are not wall material.

This is a directional geometric acceptance certificate, **not** a medial-axis,
minimum-feature-size, self-intersection, structural-strength or manufacturing
certificate. It assumes embedded, nonintersecting shells. Closed manifold edges
and vertices, consistent winding, nondegenerate triangles, and outer/cavity
orientation are checked; these checks do not establish absence of arbitrary
self-intersections. Sharp tetrahedral tips and strongly folded surfaces can have
zero clearance under this definition. A sample-based thickness display remains
an estimate and is not this verifier.

## How it works

A BVH bounds candidate triangles in each source face's inward extrusion. Target
triangles project into that face's coordinates and are clipped against its
triangle. Intersection depth is affine across the resulting convex polygon,
so checking its vertices covers the entire region, including small off-center
thin patches missed by sampled rays. Expanded clipping halfplanes preserve
possible overlaps near numerical boundaries. Scale, coordinate magnitude,
triangle conditioning, target-plane angle and floating-point roundoff determine
conservative margins; a threshold or angular-cutoff ambiguity never passes.

Shell containment uses compensated sums of analytic triangle solid angles,
following the mathematical formula described by
[Jacobson, Kavan and Sorkine-Hornung (2013)](https://users.cs.utah.edu/~ladislav/jacobson13robust/jacobson13robust.pdf).
This is an independent implementation from the published formula. No Autodesk
implementation or external Meshmixer reference output was used.

Results are `passed`, `violated`, or `indeterminate`, with diagnostics and work
counts. `verifiedLowerBound` exists only on success. `witnessClearance` is the
minimum for the **first failing triangle pair**, not the global mesh minimum.
A failing pair also supplies face IDs, a source-plane witness and its numerical
margin. On success, `numericalMargin` is the base coordinate margin; candidate
acceptance additionally applies the target-plane conditioning factor.

## Bounded reconstruction

```dart
final solid = Solidifier.makeSolid(mesh,
    mode: SolidMode.accurate, resolution: 64, minThickness: 0.8,
    maxAdditionalOffset: 0.8, maxThicknessAttempts: 6);
assert(solid.wallCertificate!.passed);
print(solid.appliedOffset);

final shell = Solidifier.hollow(mesh,
    thickness: 1.0, minThickness: 0.8, holes: 0,
    maxAdditionalThickness: 0.8);
print(shell.appliedShellThickness);
```

Positive `minThickness` enables bounded reconstruction attempts and final-mesh
verification. Make Solid supports Accurate and Blocky modes; Fast reprojection is
explicitly unsupported. Positive offsets grow the entire solid and can change
its dimensions and topology. Hollow supports enclosed cavities only: escape
holes and an open top are rejected because rims have zero local clearance.
Hollow must retain at least one cavity; removing the cavity cannot count as a
successful hollow result.

Each attempt finishes polygonization, optional field smoothing and coincident
vertex welding **before** checking the returned mesh. Nothing changes geometry
after verification. If surface nets produces nonmanifold connectivity, verified
reconstruction falls back to six consistently connected tetrahedra per cell on
the **same** SDF grid. Shared edge crossings and exact-zero lattice vertices are
deduplicated. The fallback uses piecewise-linear interpolation, so sampled sharp
corners can be beveled; it does not recover features absent from the grid.
Ordinary unverified reconstruction retains surface nets. Both polygonizers cap
verified output during generation at 500,000 faces / 1,500,000 vertices, before
welding or topology allocation. Budget exhaustion fails explicitly.

`SolidResult.reconstruction` identifies `surface-nets` or `marching-tetrahedra`;
`reconstructionDiagnostic` explains a fallback. The tetrahedral method follows
the independently implemented approach described by
[Doi and Koide (1991)](https://globals.ieice.org/en_transactions/information/10.1587/e74-d_1_214/_p).
All fallback output still must pass the final topology and clearance verifier.

The result exposes the actual total offset or SDF shell
thickness, attempt count and certificate. Requested clearance does not promise
that an offset equals half the requested increase, or that all features survive.
The default extra growth bound is the requested minimum. Hollow's bound starts
at the caller's requested `thickness`, not at `max(thickness, minThickness)`:
`appliedShellThickness <= thickness + maxAdditionalThickness`. Its first attempt
may start at the minimum only when that lies within the bound. Attempts default to 6
and cannot exceed 12. Exhaustion raises an actionable error instead of returning
an uncertified mesh. Invalid topology, poor conditioning or work-budget failure
also fails explicitly. Setting the growth bound to zero verifies one geometry
without permitting growth. `minThickness: 0` retains ordinary unverified SDF
reconstruction.

Defaults cap verification at 500,000 faces, 1,500,000 vertices, 64 shells and
5,000,000 candidate pairs. The vertex limit is always three times `maxFaces` and
is checked before validation/topology allocations, including unused vertices;
compact unused positions or explicitly raise the budget. APIs permit explicit
face/pair limits up to 2,000,000/100,000,000. Shell
nesting evaluates at most 63 other shells per source shell, bounded by the face
and shell limits. Voxel construction retains its 32-million-cell allocation cap.
All distances use the model's units.

## Studio and CLI

Studio's Make Solid and Hollow panels include **Minimum wall check (mm; 0 = off)**.
Verified operations use world millimeters, bake object transforms into the result,
preserve the world pivot, and commit one undo entry. Status reports the verified
directional clearance, actual offset/shell thickness and number of attempts.
Failed or cancelled checks preserve the original document. Choose Accurate or
Blocky for Make Solid and zero escape holes for verified Hollow.

```sh
mmx solid slab.obj verified.obj --res 64 --min-thickness 0.8 --max-growth 0.8 --attempts 6
mmx hollow model.obj shell.obj --thickness 1 --holes 0 --min-thickness 0.8
```

The CLI emits a `wallClearance` JSON record after a successful atomic export.
Invalid arguments return exit 2; an unsupported or unverified result returns exit
1 and leaves an existing output untouched. `--max-growth` bounds extra offset
for Solid or extra shell thickness for Hollow; omitted bounds equal the requested
minimum. The record describes this directional metric and its assumptions above.

## Evidence and limits

`dart test test/wall_thickness_test.dart` exercises analytical boxes across
scales, narrow off-center and near-edge thin regions, correctly wound cavities,
external gaps, inverted/degenerate meshes, numerical cutoff ambiguity and bounded
failure, unused-vertex budgets, Float32 rotations and nonuniformly scaled boxes.
Solver cases cover thin slabs at scales 0.01/1/100, boxes, spheres,
Hollow cavity retention, watertight/manifold/oriented topology and volume bounds.
A positive-offset regression also checks that exterior grid seeds have positive
distance and cannot generate a phantom shell along the grid boundary.

`test/marching_tetrahedra_test.dart` covers analytical sphere volume, exact-zero
grid nodes, cube-volume convergence with refinement, allocation guards and the
translated/rotated/nonuniform box regression. At resolution 32 and requested
clearance 1.2, that box produces a verified 19,416-face mesh after two attempts
with offset about 0.28696. Higher-resolution surface nets alone did not resolve
its ambiguous four-face edges; no resolution or smoothing override is hidden in
the fallback. An independent exhaustive check of all 255 nonempty eight-node
interior sign patterns, surrounded by positive grid boundary values, also found
closed, manifold, consistently wound outputs.

**Unknown:** parity with Meshmixer's minimum-thickness tool, printer-specific
minimum walls, and hardware/material strength. Those require separate references
or physical validation and are not inferred from these analytical tests.
