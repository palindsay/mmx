import 'dart:math' as math;
import 'dart:typed_data';

import '../geom/bbox.dart';
import '../mesh/tri_mesh.dart';
import '../mesh/material.dart';
import '../tools/pivot.dart';

/// A named object in the scene: mesh plus transform, visibility and metadata.
class SceneObject {
  final int id;
  String name;
  TriMesh mesh;
  Float64List transform;
  bool visible;
  bool isTarget;
  bool locked = false;
  int? scanSourceId;
  List<String> scanHistory = [];
  Pivot? pivot;

  SceneObject(this.id, this.name, this.mesh, {Float64List? transform})
      : transform = transform ?? identity4(),
        visible = true,
        isTarget = false;

  SceneObject clone() => SceneObject(id, name, mesh.clone(),
      transform: Float64List.fromList(transform))
    ..visible = visible
    ..isTarget = isTarget
    ..locked = locked
    ..scanSourceId = scanSourceId
    ..scanHistory = List<String>.from(scanHistory)
    ..pivot = pivot == null
        ? null
        : Pivot(
            position: List<double>.from(pivot!.position),
            normal: List<double>.from(pivot!.normal));

  BBox worldBounds() {
    final m = mesh.clone();
    m.transform(transform);
    return m.bounds();
  }

  TriMesh worldMesh() {
    final m = mesh.clone();
    m.transform(transform);
    return m;
  }
}

/// Immutable, incremental history. Unchanged geometry is shared between history
/// entries; changing a small region retains only the changed 16 KiB blocks.
/// Live meshes remain mutable and never alias the immutable history blocks.
class Document {
  final List<SceneObject> objects = <SceneObject>[];
  int _nextId = 1;
  int revision = 0;

  void replaceObjects(List<SceneObject> replacement) {
    objects
      ..clear()
      ..addAll(replacement.map((o) => o.clone()));
    _nextId = objects.fold<int>(0, (n, o) => math.max(n, o.id)) + 1;
    _undo.clear();
    _redo.clear();
    _previous.clear();
    _chunks.sweep();
    revision++;
  }

  /// Capture a rollback point, including both history stacks.
  void Function() checkpoint() {
    final saved = _capture('Rollback');
    final undo = List<_Snapshot>.from(_undo),
        redo = List<_Snapshot>.from(_redo);
    return () {
      _restore(saved);
      _undo
        ..clear()
        ..addAll(undo);
      _redo
        ..clear()
        ..addAll(redo);
      _trimHistory();
      revision++;
    };
  }

  static int objectBytes(SceneObject o) =>
      o.name.length * 2 +
      o.scanHistory.fold<int>(0, (n, entry) => n + entry.length * 2) +
      o.mesh.positions.lengthInBytes +
      o.mesh.indices.lengthInBytes +
      (o.mesh.faceGroups?.lengthInBytes ?? 0) +
      (o.mesh.vertexColors?.lengthInBytes ?? 0) +
      o.mesh.attributeBytes +
      o.transform.lengthInBytes +
      (o.pivot == null ? 0 : 48);

  /// Retained history payload, including unique geometry/texture data and
  /// metadata. VM object overhead and transient rollback checkpoints are not RSS.
  int get historyBytes {
    final chunks = Set<_HistoryChunk>.identity();
    final materials = Set<MeshMaterial>.identity();
    final textures = Set<MeshTexture>.identity();
    var bytes = 0;
    for (final snapshot in [..._undo, ..._redo]) {
      bytes += 32 + snapshot.label.length * 2;
      for (final object in snapshot.objects) {
        bytes += 32 +
            object.name.length * 2 +
            object.scanHistory
                .fold<int>(0, (n, entry) => n + entry.length * 2) +
            object.transform.lengthInBytes +
            (object.pivot == null ? 0 : 48);
        for (final buffer in object.mesh.buffers) {
          chunks.addAll(buffer.chunks);
        }
        materials.addAll(object.mesh.materials);
      }
    }
    for (final material in materials) {
      bytes += 32 + material.name.length * 2 + 32;
      if (material.texture != null) textures.add(material.texture!);
    }
    for (final texture in textures) {
      bytes += texture.byteSize + 32 + texture.name.length * 2;
    }
    return bytes + chunks.fold<int>(0, (n, chunk) => n + chunk.bytes.length);
  }

  void _trimHistory() {
    while ((_undo.length + _redo.length > maxUndoEntries ||
            historyBytes > maxUndoBytes) &&
        (_undo.isNotEmpty || _redo.isNotEmpty)) {
      if (_undo.isNotEmpty) {
        _undo.removeAt(0);
      } else {
        _redo.removeAt(0);
      }
    }
  }

  int maxUndoBytes;
  int maxUndoEntries;
  final List<_Snapshot> _undo = <_Snapshot>[];
  final List<_Snapshot> _redo = <_Snapshot>[];
  final _ChunkStore _chunks = _ChunkStore();
  final Map<int, WeakReference<_FrozenMesh>> _previous = {};

  Document(
      {this.maxUndoBytes = 512 * 1024 * 1024, this.maxUndoEntries = 1000}) {
    if (maxUndoBytes < 0 || maxUndoEntries < 0) {
      throw ArgumentError('History budgets must be nonnegative');
    }
  }

  SceneObject add(TriMesh mesh, {String? name}) {
    final obj =
        SceneObject(_nextId++, name ?? 'Object ${objects.length + 1}', mesh);
    objects.add(obj);
    revision++;
    return obj;
  }

  void remove(int id) {
    objects.removeWhere((o) => o.id == id);
    _previous.remove(id);
    revision++;
  }

  SceneObject? byId(int id) {
    for (final o in objects) {
      if (o.id == id) return o;
    }
    return null;
  }

  int get memoryBytes {
    var total = 0;
    for (final o in objects) {
      total += objectBytes(o);
    }
    return total;
  }

  void snapshot(String label) {
    final snap = _capture(label);
    _undo.add(snap);
    _redo.clear();
    revision++;
    _trimHistory();
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;

  bool undo() {
    if (_undo.isEmpty) return false;
    final snap = _undo.removeLast();
    _redo.add(_capture(snap.label));
    _restore(snap);
    revision++;
    _trimHistory();
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final snap = _redo.removeLast();
    _undo.add(_capture(snap.label));
    _restore(snap);
    revision++;
    _trimHistory();
    return true;
  }

  _Snapshot _capture(String label) {
    final captured = <_ObjectState>[];
    final liveIds = <int>{};
    for (final object in objects) {
      liveIds.add(object.id);
      final mesh = _FrozenMesh.capture(
          _chunks, object.mesh, _previous[object.id]?.target);
      _previous[object.id] = WeakReference(mesh);
      captured.add(_ObjectState(object, mesh));
    }
    _previous.removeWhere((id, _) => !liveIds.contains(id));
    _chunks.captureCompleted();
    return _Snapshot(label, captured, _nextId);
  }

  void _restore(_Snapshot snap) {
    final current = {for (final o in objects) o.id: o};
    final restored = <SceneObject>[];
    _previous.clear();
    for (final state in snap.objects) {
      final existing = current[state.id];
      // Metadata-only history never copies the unchanged large mesh again.
      // Changed objects get independent mutable arrays reconstructed from blocks.
      final mesh = existing != null && state.mesh.matches(existing.mesh)
          ? existing.mesh
          : state.mesh.restore();
      restored.add(state.restore(mesh));
      _previous[state.id] = WeakReference(state.mesh);
    }
    objects
      ..clear()
      ..addAll(restored);
    _nextId = snap.nextId;
  }
}

class _Snapshot {
  final String label;
  final List<_ObjectState> objects;
  final int nextId;
  _Snapshot(this.label, this.objects, this.nextId);
}

class _ObjectState {
  final int id;
  final String name;
  final _FrozenMesh mesh;
  final Float64List transform;
  final bool visible, isTarget, locked;
  final int? scanSourceId;
  final List<String> scanHistory;
  final Pivot? pivot;
  _ObjectState(SceneObject object, this.mesh)
      : id = object.id,
        name = object.name,
        transform = Float64List.fromList(object.transform),
        visible = object.visible,
        isTarget = object.isTarget,
        locked = object.locked,
        scanSourceId = object.scanSourceId,
        scanHistory = List<String>.unmodifiable(object.scanHistory),
        pivot = _copyPivot(object.pivot);

  static Pivot? _copyPivot(Pivot? value) => value == null
      ? null
      : Pivot(
          position: List<double>.from(value.position),
          normal: List<double>.from(value.normal));

  SceneObject restore(TriMesh mesh) =>
      SceneObject(id, name, mesh, transform: Float64List.fromList(transform))
        ..visible = visible
        ..isTarget = isTarget
        ..locked = locked
        ..scanSourceId = scanSourceId
        ..scanHistory = List<String>.from(scanHistory)
        ..pivot = _copyPivot(pivot);
}

class _FrozenMesh {
  final _FrozenBuffer positions, indices;
  final _FrozenBuffer? groups, colors, uvs, materialIds;
  final List<MeshMaterial> materials;
  _FrozenMesh(this.positions, this.indices, this.groups, this.colors, this.uvs,
      this.materialIds, this.materials);

  Iterable<_FrozenBuffer> get buffers => [
        positions,
        indices,
        if (groups != null) groups!,
        if (colors != null) colors!,
        if (uvs != null) uvs!,
        if (materialIds != null) materialIds!
      ];

  static bool sameMaterials(List<MeshMaterial> a, List<MeshMaterial> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static _FrozenMesh capture(
      _ChunkStore store, TriMesh mesh, _FrozenMesh? previous) {
    _FrozenBuffer freeze(TypedData data, _FrozenBuffer? old) =>
        _FrozenBuffer.capture(store, data, old);
    _FrozenBuffer? optional(TypedData? data, _FrozenBuffer? old) =>
        data == null ? null : freeze(data, old);
    final next = _FrozenMesh(
        freeze(mesh.positions, previous?.positions),
        freeze(mesh.indices, previous?.indices),
        optional(mesh.faceGroups, previous?.groups),
        optional(mesh.vertexColors, previous?.colors),
        optional(mesh.cornerUvs, previous?.uvs),
        optional(mesh.faceMaterials, previous?.materialIds),
        mesh.materials);
    if (previous != null &&
        identical(next.positions, previous.positions) &&
        identical(next.indices, previous.indices) &&
        identical(next.groups, previous.groups) &&
        identical(next.colors, previous.colors) &&
        identical(next.uvs, previous.uvs) &&
        identical(next.materialIds, previous.materialIds) &&
        sameMaterials(next.materials, previous.materials)) {
      return previous;
    }
    return next;
  }

  bool matches(TriMesh mesh) =>
      positions.matches(mesh.positions) &&
      indices.matches(mesh.indices) &&
      _matchesOptional(groups, mesh.faceGroups) &&
      _matchesOptional(colors, mesh.vertexColors) &&
      _matchesOptional(uvs, mesh.cornerUvs) &&
      _matchesOptional(materialIds, mesh.faceMaterials) &&
      sameMaterials(materials, mesh.materials);

  static bool _matchesOptional(_FrozenBuffer? saved, TypedData? value) =>
      saved == null ? value == null : value != null && saved.matches(value);

  TriMesh restore() => TriMesh(positions.restore().buffer.asFloat32List(),
      indices.restore().buffer.asUint32List(),
      faceGroups: groups?.restore().buffer.asUint16List(),
      vertexColors: colors?.restore().buffer.asFloat32List(),
      cornerUvs: uvs?.restore().buffer.asFloat32List(),
      faceMaterials: materialIds?.restore().buffer.asUint16List(),
      materials: materials);
}

class _FrozenBuffer {
  static const blockBytes = 16 * 1024;
  final int length;
  final List<_HistoryChunk> chunks;
  _FrozenBuffer(this.length, this.chunks);

  static _FrozenBuffer capture(
      _ChunkStore store, TypedData data, _FrozenBuffer? old) {
    final source =
        ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
    final chunks = <_HistoryChunk>[];
    var unchanged = old != null && old.length == source.lengthInBytes;
    for (var offset = 0, index = 0;
        offset < source.lengthInBytes;
        offset += blockBytes, index++) {
      final length = math.min(blockBytes, source.lengthInBytes - offset);
      final prior =
          old != null && index < old.chunks.length ? old.chunks[index] : null;
      if (prior != null && prior.matches(source, offset, length)) {
        chunks.add(prior);
      } else {
        unchanged = false;
        chunks.add(store.intern(source, offset, length));
      }
    }
    return unchanged ? old! : _FrozenBuffer(source.lengthInBytes, chunks);
  }

  bool matches(TypedData data) {
    if (length != data.lengthInBytes) return false;
    final source = ByteData.view(data.buffer, data.offsetInBytes, length);
    for (var i = 0; i < chunks.length; i++) {
      if (!chunks[i].matches(source, i * blockBytes, chunks[i].bytes.length)) {
        return false;
      }
    }
    return true;
  }

  Uint8List restore() {
    final out = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      out.setRange(offset, offset + chunk.bytes.length, chunk.bytes);
      offset += chunk.bytes.length;
    }
    return out;
  }
}

class _HistoryChunk {
  final Uint8List bytes;
  final ByteData _view;
  _HistoryChunk(Uint8List copy)
      : bytes = copy,
        _view = ByteData.sublistView(copy);

  bool matches(ByteData source, int offset, int length) {
    if (length != bytes.length) return false;
    var i = 0;
    for (; i + 4 <= length; i += 4) {
      if (_view.getUint32(i) != source.getUint32(offset + i)) return false;
    }
    for (; i < length; i++) {
      if (bytes[i] != source.getUint8(offset + i)) return false;
    }
    return true;
  }
}

class _ChunkStore {
  // Weak indexing means evicted history/checkpoints do not retain geometry.
  final Map<int, List<WeakReference<_HistoryChunk>>> _buckets = {};
  int _captures = 0;

  _HistoryChunk intern(ByteData source, int offset, int length) {
    var hash = 0x811c9dc5, i = 0;
    for (; i + 4 <= length; i += 4) {
      hash = ((hash ^ source.getUint32(offset + i)) * 0x01000193) & 0xffffffff;
    }
    for (; i < length; i++) {
      hash = ((hash ^ source.getUint8(offset + i)) * 0x01000193) & 0xffffffff;
    }
    final bucket = _buckets.putIfAbsent(hash, () => []);
    bucket.removeWhere((reference) => reference.target == null);
    for (final reference in bucket) {
      final chunk = reference.target;
      // Hashes only select candidates: compare bytes to make collisions harmless.
      if (chunk != null && chunk.matches(source, offset, length)) return chunk;
    }
    final copy = Uint8List.fromList(
        Uint8List.view(source.buffer, source.offsetInBytes + offset, length));
    final chunk = _HistoryChunk(copy);
    bucket.add(WeakReference(chunk));
    return chunk;
  }

  void captureCompleted() {
    if (++_captures % 64 == 0) sweep();
  }

  void sweep() {
    _buckets.removeWhere((_, bucket) {
      bucket.removeWhere((reference) => reference.target == null);
      return bucket.isEmpty;
    });
  }
}

Float64List identity4() => Float64List.fromList(<double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]);

/// Column-major translation.
Float64List translation4(double x, double y, double z) =>
    Float64List.fromList(<double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      x,
      y,
      z,
      1,
    ]);

Float64List scale4(double s) => Float64List.fromList(<double>[
      s,
      0,
      0,
      0,
      0,
      s,
      0,
      0,
      0,
      0,
      s,
      0,
      0,
      0,
      0,
      1,
    ]);

/// Rotation about an arbitrary axis (column-major).
Float64List rotation4(double ax, double ay, double az, double radians) {
  final l = ax * ax + ay * ay + az * az;
  if (l < 1e-20) return identity4();
  final n = 1.0 / (l > 0 ? math.sqrt(l) : 1);
  final x = ax * n, y = ay * n, z = az * n;
  final c = math.cos(radians), s = math.sin(radians), t = 1 - c;
  return Float64List.fromList(<double>[
    t * x * x + c,
    t * x * y - s * z,
    t * x * z + s * y,
    0,
    t * x * y + s * z,
    t * y * y + c,
    t * y * z - s * x,
    0,
    t * x * z - s * y,
    t * y * z + s * x,
    t * z * z + c,
    0,
    0,
    0,
    0,
    1,
  ]);
}

/// Multiplies column-major 4x4 matrices: a * b.
Float64List multiply4(Float64List a, Float64List b) {
  final out = Float64List(16);
  for (var col = 0; col < 4; col++) {
    for (var row = 0; row < 4; row++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[k * 4 + row] * b[col * 4 + k];
      }
      out[col * 4 + row] = s;
    }
  }
  return out;
}
