# Materials, textures and parser boundaries

## Supported workflow

Studio's Materials panel assigns a diffuse RGBA color and an optional PNG/JPEG
texture to the selected object. Generate planar UVs before assigning a texture
when the mesh has no mapping. Apply creates one undo step. Native `.mmx` projects
retain material names, assignments, original encoded images and UV seams.
All new projects use schema 3, including geometry-only projects. Schema 1/2
remain readable; schema 3 additionally retains protected originals, scan history
and printer profiles. Earlier releases reject schema 3. Use Save As to retain an
older project copy before migration.

The CPU and GPU viewports multiply material color, vertex RGB and sampled texture
color, with perspective-correct UV interpolation and bilinear filtering. UVs use
v-up; decoded pixel rows run top-down. Both viewports use **alpha cutout**: alpha
below 0.5 is discarded, other fragments are opaque. Stored alpha values remain
unchanged. Sorted translucent rendering and ICC/profile color management are not
implemented.

## File interoperability

| Format | Supported material data | Explicit limitations |
| --- | --- | --- |
| Native `.mmx` | Diffuse RGBA, per-face material assignments, per-corner UVs, shared PNG/JPEG sources | No PBR or multilayer material model |
| OBJ + MTL | `vt`, independent/negative UV indices, `Kd`, `d`/`Tr`, `map_Kd`, clamp/repeat | One library per `mtllib` line; nonzero specular/ambient/emission, refraction and other texture operations reject |
| 3MF | Base RGBA; diffuse PNG/JPEG textures; plain vertex RGB groups | No PBR, composites, mixed vertex-color/material properties, color seams, tinted textures, mirror addressing or nearest filtering; naked UVs require OBJ/native |
| STL, PLY, MIX | Existing geometry/color/group support | Export with UV/material attributes rejects; explicitly remove surface attributes first |

OBJ file import resolves companion paths within the selected file's directory.
Exports stage a private sibling `mmx-assets-*` directory before atomically
replacing the OBJ. Move that directory together with the OBJ. Older asset
directories are retained on overwrite so existing references remain usable.

```sh
cd packages/mmx_core
dart run bin/mmx.dart convert input.obj output.3mf
dart run bin/mmx.dart convert input.3mf output.obj
dart test test/material_fidelity_test.dart test/io_fidelity_test.dart
```

`MeshIO.readBytes` cannot resolve filesystem companions; use `readFile`, or supply
`ObjIO.read(..., readAsset: ...)`. Cancellable workers call `prepareExport`; commit
the returned bytes with `commitExport` only after cancellation/revision checks.

## Editing and resource limits

Transforms, smoothing, non-refining deformation/sculpting, winding reversal,
mirroring, combination, welding, non-manifold fan splitting, bounded scan
denoising and face extraction retain surface attributes.
Linear subdivision interpolates UVs separately on each side of a seam. Remeshing,
decimation, cuts, extrusion, hole filling, dynamic sculpt topology and booleans
reject attributed meshes when they cannot preserve the mapping.

Each texture is limited to 4096 pixels per dimension, 16 megapixels and 16 MiB of
encoded bytes. An import/project permits 192 MiB of combined encoded/decoded
texture data. OBJ filesystem companions additionally have a 64 MiB encoded total.
Absolute/network/traversal paths and escaping symlinks reject. PNG compressed
ancillary metadata is excluded from decoding while original bytes are retained.

Seeded mutation tests exercise actual OBJ/MTL, PNG/JPEG, 3MF, project, PLY, STL,
OFF and MIX parsers. Round-trip tests check UV seams, material/image retention,
rendered pixels and geometry invariants. These are bounded regression tests, not
a claim of exhaustive fuzz coverage.

The material behavior is **inferred**, implemented from public formats and local
tests. See the [3MF materials specification](https://github.com/3MFConsortium/spec_materials)
and [Dart image decoder documentation](https://github.com/brendan-duncan/image/blob/main/doc/formats.md).
Opaque imported MIX records remain original source attachments; their material
semantics remain **unknown** and are not claimed to be decoded.
