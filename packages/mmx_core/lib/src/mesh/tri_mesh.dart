import 'dart:math' as math;
import 'dart:typed_data';

import '../geom/bbox.dart';
import 'material.dart';

/// Indexed triangle mesh: the single geometry container used by every
/// operator in this kernel. Positions and indices are flat typed arrays so
/// hot loops stay allocation free, and so the same buffers can be handed to
/// a GPU or a worker isolate without per-element boxing.
class TriMesh {
  Float32List positions;
  Uint32List indices;

  /// Per-face group id (face groups / material regions). Optional.
  Uint16List? faceGroups;

  /// Per-vertex RGB, 3 floats per vertex. Optional.
  Float32List? vertexColors;

  /// UV pairs per triangle corner (indices.length * 2); permits UV seams.
  Float32List? cornerUvs;

  /// Per-face index into [materials]. All faces need an assignment when present.
  Uint16List? faceMaterials;
  List<MeshMaterial> _materials;
  List<MeshMaterial> get materials => _materials;
  set materials(List<MeshMaterial> value) =>
      _materials = List.unmodifiable(value);

  TriMesh(this.positions, this.indices,
      {this.faceGroups,
      this.vertexColors,
      this.cornerUvs,
      this.faceMaterials,
      List<MeshMaterial> materials = const []})
      : _materials = List.unmodifiable(materials);

  /// Mutable geometry/attribute storage; immutable textures can be shared safely.
  List<TypedData> get dataBuffers => [
        positions,
        indices,
        if (faceGroups != null) faceGroups!,
        if (vertexColors != null) vertexColors!,
        if (cornerUvs != null) cornerUvs!,
        if (faceMaterials != null) faceMaterials!
      ];
  int get attributeBytes =>
      (cornerUvs?.lengthInBytes ?? 0) +
      (faceMaterials?.lengthInBytes ?? 0) +
      materials
          .map((m) => m.texture)
          .whereType<MeshTexture>()
          .toSet()
          .fold<int>(0, (n, t) => n + t.byteSize);
  bool get hasSurfaceAttributes =>
      cornerUvs != null || materials.isNotEmpty || faceMaterials != null;
  void requireUntextured(String operation) {
    if (hasSurfaceAttributes) {
      throw UnsupportedError(
          '$operation cannot preserve UV/material assignments. Remove materials and UVs explicitly first.');
    }
  }

  factory TriMesh.empty() => TriMesh(Float32List(0), Uint32List(0));

  int get vertexCount => positions.length ~/ 3;
  int get faceCount => indices.length ~/ 3;

  double vx(int i) => positions[i * 3];
  double vy(int i) => positions[i * 3 + 1];
  double vz(int i) => positions[i * 3 + 2];

  TriMesh clone() => TriMesh(
        Float32List.fromList(positions),
        Uint32List.fromList(indices),
        faceGroups:
            faceGroups == null ? null : Uint16List.fromList(faceGroups!),
        vertexColors:
            vertexColors == null ? null : Float32List.fromList(vertexColors!),
        cornerUvs: cornerUvs == null ? null : Float32List.fromList(cornerUvs!),
        faceMaterials:
            faceMaterials == null ? null : Uint16List.fromList(faceMaterials!),
        materials: materials,
      );

  BBox bounds() {
    final b = BBox();
    for (var i = 0; i < positions.length; i += 3) {
      b.add(positions[i], positions[i + 1], positions[i + 2]);
    }
    return b;
  }

  /// Signed volume via the divergence theorem (positive for outward normals).
  double signedVolume() {
    var vol = 0.0;
    for (var f = 0; f < indices.length; f += 3) {
      final a = indices[f] * 3, b = indices[f + 1] * 3, c = indices[f + 2] * 3;
      final ax = positions[a], ay = positions[a + 1], az = positions[a + 2];
      final bx = positions[b], by = positions[b + 1], bz = positions[b + 2];
      final cx = positions[c], cy = positions[c + 1], cz = positions[c + 2];
      vol += _det(ax, ay, az, bx, by, bz, cx, cy, cz);
    }
    return vol / 6.0;
  }

  double surfaceArea() {
    var area = 0.0;
    for (var f = 0; f < indices.length; f += 3) {
      final a = indices[f] * 3, b = indices[f + 1] * 3, c = indices[f + 2] * 3;
      final ux = positions[b] - positions[a];
      final uy = positions[b + 1] - positions[a + 1];
      final uz = positions[b + 2] - positions[a + 2];
      final wx = positions[c] - positions[a];
      final wy = positions[c + 1] - positions[a + 1];
      final wz = positions[c + 2] - positions[a + 2];
      final nx = uy * wz - uz * wy;
      final ny = uz * wx - ux * wz;
      final nz = ux * wy - uy * wx;
      area += 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz);
    }
    return area;
  }

  /// Vertex-area weighted centroid.
  List<double> centroid() {
    var sx = 0.0, sy = 0.0, sz = 0.0, sw = 0.0;
    for (var f = 0; f < indices.length; f += 3) {
      final ia = indices[f], ib = indices[f + 1], ic = indices[f + 2];
      final ax = vx(ia), ay = vy(ia), az = vz(ia);
      final ux = vx(ib) - ax, uy = vy(ib) - ay, uz = vz(ib) - az;
      final wx = vx(ic) - ax, wy = vy(ic) - ay, wz = vz(ic) - az;
      final nx = uy * wz - uz * wy,
          ny = uz * wx - ux * wz,
          nz = ux * wy - uy * wx;
      final a = 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz);
      sx += a * (ax + vx(ib) + vx(ic)) / 3.0;
      sy += a * (ay + vy(ib) + vy(ic)) / 3.0;
      sz += a * (az + vz(ib) + vz(ic)) / 3.0;
      sw += a;
    }
    if (sw == 0) return <double>[0, 0, 0];
    return <double>[sx / sw, sy / sw, sz / sw];
  }

  /// Applies a column-major 4x4 affine transform in place.
  void transform(Float64List m) {
    if (m.length != 16 ||
        m.any((v) => !v.isFinite) ||
        m[3] != 0 ||
        m[7] != 0 ||
        m[11] != 0 ||
        m[15] != 1) {
      throw ArgumentError('Expected a finite affine 4x4 transform');
    }
    final determinant =
        _det(m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10]);
    if (!determinant.isFinite || determinant == 0) {
      throw ArgumentError('Singular transform');
    }
    final transformed = Float32List(positions.length);
    for (var i = 0; i < positions.length; i += 3) {
      final x = positions[i], y = positions[i + 1], z = positions[i + 2];
      transformed[i] = m[0] * x + m[4] * y + m[8] * z + m[12];
      transformed[i + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
      transformed[i + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
    }
    if (transformed.any((v) => !v.isFinite)) {
      throw ArgumentError('Transform exceeds float32 range');
    }
    positions = transformed;
    // Reflections reverse handedness. Keep outward-facing winding.
    if (determinant < 0) {
      for (var f = 0; f < indices.length; f += 3) {
        reverseFace(f ~/ 3);
      }
    }
  }

  /// Reverse winding and associated corner UVs together.
  void reverseFace(int face) {
    final f = face * 3;
    final tmp = indices[f + 1];
    indices[f + 1] = indices[f + 2];
    indices[f + 2] = tmp;
    if (cornerUvs != null) {
      for (var k = 0; k < 2; k++) {
        final t = cornerUvs![(f + 1) * 2 + k];
        cornerUvs![(f + 1) * 2 + k] = cornerUvs![(f + 2) * 2 + k];
        cornerUvs![(f + 2) * 2 + k] = t;
      }
    }
  }

  /// Extract faces while preserving per-face groups and per-vertex colors.
  TriMesh extractFaces(Iterable<int> faces) {
    final builder = MeshBuilder();
    final remap = <int, int>{};
    final groups = faceGroups == null ? null : <int>[];
    final colors = vertexColors == null ? null : <double>[];
    final uvs = cornerUvs == null ? null : <double>[];
    final materialIds = faceMaterials == null ? null : <int>[];
    for (final face in faces) {
      if (face < 0 || face >= faceCount) {
        throw RangeError.index(face, indices, 'face');
      }
      final mapped = <int>[];
      for (var k = 0; k < 3; k++) {
        final v = indices[face * 3 + k];
        mapped.add(remap.putIfAbsent(v, () {
          colors?.addAll(vertexColors!.sublist(v * 3, v * 3 + 3));
          return builder.addVertex(vx(v), vy(v), vz(v));
        }));
      }
      builder.addTriangle(mapped[0], mapped[1], mapped[2]);
      groups?.add(faceGroups![face]);
      uvs?.addAll(cornerUvs!.sublist(face * 6, face * 6 + 6));
      materialIds?.add(faceMaterials![face]);
    }
    return builder.build()
      ..faceGroups = groups == null ? null : Uint16List.fromList(groups)
      ..vertexColors = colors == null ? null : Float32List.fromList(colors)
      ..cornerUvs = uvs == null ? null : Float32List.fromList(uvs)
      ..faceMaterials =
          materialIds == null ? null : Uint16List.fromList(materialIds)
      ..materials = materials;
  }

  /// Drops faces with repeated indices or (near) zero area.
  int removeDegenerateFaces({double minArea = 1e-14}) {
    final keep = <int>[];
    final groups = faceGroups == null ? null : <int>[];
    final uvs = cornerUvs == null ? null : <double>[];
    final materialIds = faceMaterials == null ? null : <int>[];
    for (var f = 0; f < indices.length; f += 3) {
      final ia = indices[f], ib = indices[f + 1], ic = indices[f + 2];
      if (ia == ib || ib == ic || ia == ic) continue;
      final ax = vx(ia), ay = vy(ia), az = vz(ia);
      final ux = vx(ib) - ax, uy = vy(ib) - ay, uz = vz(ib) - az;
      final wx = vx(ic) - ax, wy = vy(ic) - ay, wz = vz(ic) - az;
      final nx = uy * wz - uz * wy,
          ny = uz * wx - ux * wz,
          nz = ux * wy - uy * wx;
      if (0.5 * math.sqrt(nx * nx + ny * ny + nz * nz) <= minArea) continue;
      groups?.add(faceGroups![f ~/ 3]);
      uvs?.addAll(cornerUvs!.sublist(f * 2, f * 2 + 6));
      materialIds?.add(faceMaterials![f ~/ 3]);
      keep.add(ia);
      keep.add(ib);
      keep.add(ic);
    }
    final removed = (indices.length - keep.length) ~/ 3;
    if (removed > 0) {
      indices = Uint32List.fromList(keep);
      if (groups != null) faceGroups = Uint16List.fromList(groups);
      if (uvs != null) cornerUvs = Float32List.fromList(uvs);
      if (materialIds != null) faceMaterials = Uint16List.fromList(materialIds);
    }
    return removed;
  }

  /// Removes vertices not referenced by any face and remaps indices.
  void compact() {
    final used = Uint8List(vertexCount);
    for (final i in indices) {
      used[i] = 1;
    }
    final remap = Uint32List(vertexCount);
    var n = 0;
    for (var i = 0; i < vertexCount; i++) {
      if (used[i] == 1) {
        remap[i] = n++;
      }
    }
    if (n == vertexCount) return;
    final np = Float32List(n * 3);
    Float32List? nc;
    if (vertexColors != null) nc = Float32List(n * 3);
    for (var i = 0; i < vertexCount; i++) {
      if (used[i] != 1) continue;
      final d = remap[i] * 3;
      np[d] = positions[i * 3];
      np[d + 1] = positions[i * 3 + 1];
      np[d + 2] = positions[i * 3 + 2];
      if (nc != null) {
        nc[d] = vertexColors![i * 3];
        nc[d + 1] = vertexColors![i * 3 + 1];
        nc[d + 2] = vertexColors![i * 3 + 2];
      }
    }
    final ni = Uint32List(indices.length);
    for (var i = 0; i < indices.length; i++) {
      ni[i] = remap[indices[i]];
    }
    positions = np;
    indices = ni;
    vertexColors = nc;
  }

  /// Returns human-readable problems; empty list means structurally sane.
  List<String> validate() {
    final issues = <String>[];
    if (positions.length % 3 != 0) issues.add('positions not a multiple of 3');
    if (indices.length % 3 != 0) issues.add('indices not a multiple of 3');
    if (faceGroups != null && faceGroups!.length != faceCount) {
      issues.add('face group count mismatch');
    }
    if (vertexColors != null &&
        (vertexColors!.length != positions.length ||
            vertexColors!.any((v) => !v.isFinite))) {
      issues.add('invalid vertex colors');
    }
    if (cornerUvs != null &&
        (cornerUvs!.length != indices.length * 2 ||
            cornerUvs!.any((v) => !v.isFinite))) {
      issues.add('invalid corner UVs');
    }
    if (materials.length > 4096 ||
        (faceMaterials != null &&
            (faceMaterials!.length != faceCount ||
                faceMaterials!.any((id) => id >= materials.length))) ||
        (materials.isNotEmpty && faceMaterials == null)) {
      issues.add('invalid material assignments');
    }
    if (materials.any((m) => m.texture != null) && cornerUvs == null) {
      issues.add('texture requires UVs');
    }
    if (attributeBytes > 192 * 1024 * 1024) {
      issues.add('surface attributes exceed 192 MiB limit');
    }
    final n = vertexCount;
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= n) {
        issues.add('index ${indices[i]} out of range (verts=$n)');
        break;
      }
    }
    for (var i = 0; i < positions.length; i++) {
      if (!positions[i].isFinite) {
        issues.add('non-finite position at $i');
        break;
      }
    }
    return issues;
  }

  static double _det(double ax, double ay, double az, double bx, double by,
      double bz, double cx, double cy, double cz) {
    return ax * (by * cz - bz * cy) -
        ay * (bx * cz - bz * cx) +
        az * (bx * cy - by * cx);
  }
}

/// Incremental builder for operator output.
class MeshBuilder {
  final List<double> _p = <double>[];
  final List<int> _i = <int>[];

  int addVertex(double x, double y, double z) {
    final id = _p.length ~/ 3;
    _p.addAll(<double>[x, y, z]);
    return id;
  }

  void addTriangle(int a, int b, int c) => _i.addAll(<int>[a, b, c]);

  int get vertexCount => _p.length ~/ 3;
  int get faceCount => _i.length ~/ 3;

  TriMesh build() {
    final positions = Float32List(_p.length);
    for (var i = 0; i < _p.length; i++) {
      positions[i] = _p[i];
    }
    final indices = Uint32List(_i.length);
    for (var i = 0; i < _i.length; i++) {
      indices[i] = _i[i];
    }
    return TriMesh(positions, indices);
  }
}

/// Builds a closed cylinder mesh from p0 to p1 (used for support posts).
TriMesh cylinderMesh(List<double> p0, List<double> p1, double r0, double r1,
    {int sides = 12, bool caps = true}) {
  final b = MeshBuilder();
  final dx = p1[0] - p0[0], dy = p1[1] - p0[1], dz = p1[2] - p0[2];
  final len = length3(dx, dy, dz);
  if (len < 1e-9) return TriMesh.empty();
  final ux = dx / len, uy = dy / len, uz = dz / len;
  // Pick a stable perpendicular basis.
  var tx = 0.0, ty = 0.0, tz = 0.0;
  if (ux.abs() < 0.9) {
    tx = 0;
    ty = -uz;
    tz = uy;
  } else {
    tx = uz;
    ty = 0;
    tz = -ux;
  }
  final tl = length3(tx, ty, tz);
  tx /= tl;
  ty /= tl;
  tz /= tl;
  final bx = uy * tz - uz * ty, by = uz * tx - ux * tz, bz = ux * ty - uy * tx;

  final ring0 = <int>[];
  final ring1 = <int>[];
  for (var s = 0; s < sides; s++) {
    final a = 2 * math.pi * s / sides;
    final ca = math.cos(a), sa = math.sin(a);
    final ox = tx * ca + bx * sa,
        oy = ty * ca + by * sa,
        oz = tz * ca + bz * sa;
    ring0.add(b.addVertex(p0[0] + ox * r0, p0[1] + oy * r0, p0[2] + oz * r0));
    ring1.add(b.addVertex(p1[0] + ox * r1, p1[1] + oy * r1, p1[2] + oz * r1));
  }
  for (var s = 0; s < sides; s++) {
    final s2 = (s + 1) % sides;
    b.addTriangle(ring0[s], ring1[s], ring1[s2]);
    b.addTriangle(ring0[s], ring1[s2], ring0[s2]);
  }
  if (caps) {
    final c0 = b.addVertex(p0[0], p0[1], p0[2]);
    final c1 = b.addVertex(p1[0], p1[1], p1[2]);
    for (var s = 0; s < sides; s++) {
      final s2 = (s + 1) % sides;
      b.addTriangle(c0, ring0[s2], ring0[s]);
      b.addTriangle(c1, ring1[s], ring1[s2]);
    }
  }
  return b.build();
}
