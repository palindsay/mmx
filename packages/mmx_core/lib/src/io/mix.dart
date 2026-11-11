import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';

/// A scene object recovered from a `.mix` file.
class MixObject {
  final String name;
  final TriMesh mesh;

  const MixObject({required this.name, required this.mesh});
}

/// Native Meshmixer scene (`.mix`).
///
/// The container is a sequence of length-prefixed records:
///
///   1. XML scene description (`<SceneObjects>`, `<MeshSO9>`, `<SemanticDB>`)
///   2. a block index (block ids and sizes)
///   3. `MMGS` / `GSurf 01.01` / `VFMesh 1.3` binary mesh blocks
///   4. an `MMSDB` / `SemanticDB 01.20` block
///
/// Mesh blocks are a fixed 64-byte header followed by 60-byte vertex records
/// (record size, vertex id, position, normal, vertex count, 0, RGBA, 0) and
/// 28-byte face records (record size, face id, three indices, 0, -1), then a
/// constant `MeshPolygons 1.0` trailer. All integers are little-endian.
class MixIO {
  static const int _vertexRecordSize = 60;
  static const int _faceRecordSize = 28;
  static const int _vertexPayload = 56;
  static const int _facePayload = 24;

  /// Constant trailer written by Meshmixer for a single-group triangle mesh.
  static const List<int> _polygonTrailer = <int>[
    0x11,
    0x00,
    0x00,
    0x00,
    0x4d,
    0x65,
    0x73,
    0x68,
    0x50,
    0x6f,
    0x6c,
    0x79,
    0x67,
    0x6f,
    0x6e,
    0x73,
    0x20,
    0x31,
    0x2e,
    0x30,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xde,
    0x73,
    0xbf,
    0x00,
    0x00,
    0x00,
    0xc0,
    0x03,
    0xf8,
    0x38,
    0x40,
    0x00,
    0x00,
    0x00,
    0x00,
    0x80,
    0xf1,
    0x82,
    0x3f,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xf0,
    0x3f,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xf0,
    0x3f,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xf0,
    0x3f,
    0x30,
    0xd6,
    0x5e,
    0xbd,
    0x75,
    0xbe,
    0xa3,
    0x3f,
    0x30,
    0xd6,
    0x5e,
    0xbd,
    0x75,
    0xbe,
    0xa3,
    0x3f,
    0x30,
    0xd6,
    0x5e,
    0xbd,
    0x75,
    0xbe,
    0xa3,
    0x3f,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xde,
    0x73,
    0x3f,
    0x00,
    0x00,
    0x00,
    0xc0,
    0x03,
    0xf8,
    0x38,
    0xc0,
    0x00,
    0x00,
    0x00,
    0x00,
    0x80,
    0xf1,
    0x82,
    0xbf,
    0x00,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
  ];

  static const List<int> _semanticBlock = <int>[
    0x06, 0x00, 0x00, 0x00, // u32 6
    0x4d, 0x4d, 0x53, 0x44, 0x42, 0x00, // "MMSDB\0"
    0x11, 0x00, 0x00, 0x00, // u32 17
    0x53, 0x65, 0x6d, 0x61, 0x6e, 0x74, 0x69, 0x63, 0x44, 0x42, 0x20,
    0x30, 0x31, 0x2e, 0x32, 0x30, 0x00, // "SemanticDB 01.20\0"
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];

  static MixObject? _readMeshBlock(Uint8List payload) {
    if (payload.length < 64) return null;
    final tagLen = _u32(payload, 0);
    if (tagLen <= 0 || 4 + tagLen + 4 > payload.length) return null;
    final tag = String.fromCharCodes(payload.sublist(4, 4 + tagLen));
    if (!tag.startsWith('MMGS')) return null;

    var off = 4 + tagLen;
    final surfLen = _u32(payload, off);
    off += 4 + surfLen;
    if (off + 4 > payload.length) {
      throw const FormatException('Truncated MMGS header');
    }
    final meshLen = _u32(payload, off);
    if (off + 4 + meshLen > payload.length) return null;
    final meshTag =
        String.fromCharCodes(payload.sublist(off + 4, off + 4 + meshLen));
    off += 4 + meshLen;

    var vStride = _vertexRecordSize;
    var vPosOffset = 8;
    var fStride = _faceRecordSize;
    var fIndexOffset = 8;
    var fGroupOffset = 20;
    if (meshTag.startsWith('VFMesh 1.2')) {
      // Older layout: four counts, then 56-byte vertex records with the id
      // first and the position at +4, and 20-byte face records
      // (id, a, b, c, group).
      if (off + 16 > payload.length) return null;
      final nv12 = _u32(payload, off);
      final nf12 = _u32(payload, off + 8);
      off += 16;
      vStride = 56;
      vPosOffset = 4;
      fStride = 20;
      fIndexOffset = 4;
      fGroupOffset = 16;
      return _readRecords(payload, off, nv12, nf12, vStride, vPosOffset,
          fStride, fIndexOffset, fGroupOffset);
    }
    if (off + 24 > payload.length) return null;

    final nv = _u32(payload, off);
    final nf = _u32(payload, off + 8);
    final vPayload = _u32(payload, off + 16);
    final fPayload = _u32(payload, off + 20);
    off += 24;
    vStride = vPayload + 4;
    fStride = fPayload + 4;
    return _readRecords(payload, off, nv, nf, vStride, vPosOffset, fStride,
        fIndexOffset, fGroupOffset);
  }

  static MixObject? _readRecords(
    Uint8List payload,
    int off,
    int nv,
    int nf,
    int vStride,
    int vPosOffset,
    int fStride,
    int fIndexOffset,
    int fGroupOffset,
  ) {
    if (nv <= 0 || nf <= 0) return null;
    if (nv > 2000000 ||
        nf > 4000000 ||
        vStride < vPosOffset + 12 ||
        fStride < fIndexOffset + 12 ||
        fStride < fGroupOffset + 4 ||
        off + nv * vStride + nf * fStride > payload.length) {
      throw const FormatException('Invalid or oversized MMGS records');
    }

    final positions = Float32List(nv * 3);
    for (var i = 0; i < nv; i++) {
      final base = off + i * vStride + vPosOffset;
      positions[i * 3] = _f32(payload, base);
      positions[i * 3 + 1] = _f32(payload, base + 4);
      positions[i * 3 + 2] = _f32(payload, base + 8);
    }
    final faceOff = off + nv * vStride;
    final indices = Uint32List(nf * 3);
    final groups = Uint16List(nf);
    var hasGroups = false;
    for (var i = 0; i < nf; i++) {
      final rec = faceOff + i * fStride;
      final base = rec + fIndexOffset;
      indices[i * 3] = _u32(payload, base);
      indices[i * 3 + 1] = _u32(payload, base + 4);
      indices[i * 3 + 2] = _u32(payload, base + 8);
      final group = _u32(payload, rec + fGroupOffset);
      if (group != 0 && group != 0xFFFFFFFF) {
        groups[i] = group > 0xFFFF ? 0xFFFF : group;
        hasGroups = true;
      }
      if (indices[i * 3] >= nv ||
          indices[i * 3 + 1] >= nv ||
          indices[i * 3 + 2] >= nv) {
        throw const FormatException('Invalid MMGS triangle index');
      }
    }
    if (positions.any((v) => !v.isFinite)) {
      throw const FormatException('Non-finite MMGS coordinate');
    }
    return MixObject(
        name: 'Mesh',
        mesh:
            TriMesh(positions, indices, faceGroups: hasGroups ? groups : null));
  }

  /// Rewrites mesh blocks in an existing scene while preserving every other
  /// record byte-for-byte: XML scene objects (including PivotSO/DecalSO),
  /// semantic blocks and any unknown blocks. Rejects unmappable input instead
  /// of silently discarding metadata; use [write] explicitly for a new scene.
  static Uint8List rewrite(Uint8List original, List<MixObject> objects) {
    final usable = objects.where((o) => o.mesh.faceCount > 0).toList();
    final recs = _splitRecords(original);
    if (recs.length < 4 || usable.isEmpty) {
      throw const FormatException('Cannot preserve records for this scene');
    }

    final xml = utf8.decode(recs[0], allowMalformed: true);
    final ids = <int>[];
    final objectRe = RegExp(r'<MeshSO\d*>(.*?)</MeshSO\d*>', dotAll: true);
    for (final m in objectRe.allMatches(xml)) {
      final body = m.group(1) ?? '';
      final vis = RegExp(r'<Visibility>(\d+)</Visibility>').firstMatch(body);
      if (vis != null && vis.group(1) == '0') continue;
      final block =
          RegExp(r'<MeshBlockID>(\d+)</MeshBlockID>').firstMatch(body);
      if (block != null) ids.add(int.parse(block.group(1)!));
    }
    if (ids.length != usable.length || ids.toSet().length != ids.length) {
      throw const FormatException(
          'Cannot map rewritten objects to original records');
    }

    final index = recs[1];
    var off = 0;
    final count = _u32(index, off);
    off += 4;
    if (count > 4096 ||
        count > recs.length - 2 ||
        4 + count * 8 > index.length) {
      throw const FormatException('Invalid MIX block index');
    }
    final entries = <List<int>>[];
    for (var i = 0; i < count; i++) {
      final entry = [_u32(index, off), _u32(index, off + 4)];
      if (entries.any((e) => e[0] == entry[0]) ||
          entry[1] != recs[i + 2].length) {
        throw const FormatException('MIX block index does not match records');
      }
      entries.add(entry);
      off += 8;
    }

    if (ids.any((id) => !entries.any((e) => e[0] == id))) {
      throw const FormatException('Missing MIX mesh record');
    }
    final replacements = <int, Uint8List>{};
    for (var i = 0; i < ids.length; i++) {
      replacements[ids[i]] = _meshBlock(usable[i].mesh);
    }

    final newIndex = BytesBuilder();
    _writeU32(newIndex, count);
    for (final e in entries) {
      _writeU32(newIndex, e[0]);
      _writeU32(newIndex, replacements[e[0]]?.length ?? e[1]);
    }

    final out = BytesBuilder();
    void record(List<int> payload) {
      _writeU32(out, payload.length);
      out.add(payload);
    }

    record(recs[0]);
    record(newIndex.toBytes());
    var pos = 2;
    for (final e in entries) {
      record(replacements[e[0]] ?? recs[pos]);
      pos++;
    }
    while (pos < recs.length) {
      record(recs[pos++]);
    }
    return out.toBytes();
  }

  static List<Uint8List> _splitRecords(Uint8List bytes) {
    if (bytes.length > 256 * 1024 * 1024) {
      throw const FormatException('MIX exceeds size limit');
    }
    final out = <Uint8List>[];
    var off = 0;
    while (off < bytes.length) {
      if (out.length >= 4096 || off + 4 > bytes.length) {
        throw const FormatException('Invalid MIX records');
      }
      final len = _u32(bytes, off);
      if (len == 0 || len > bytes.length - off - 4) {
        throw const FormatException('Truncated MIX record');
      }
      out.add(Uint8List.sublistView(bytes, off + 4, off + 4 + len));
      off += 4 + len;
    }
    return out;
  }

  /// Reads every mesh object in the scene. Returns an empty list when the
  /// container has no readable MMGS block.
  static List<MixObject> read(Uint8List bytes) {
    final meshes = <MixObject>[];
    final names = <int, String>{};
    var nextBlock = 1;
    for (final payload in _splitRecords(bytes)) {
      if (payload.length > 5 && payload[0] == 0x3c && payload[1] == 0x3f) {
        // XML record: pull names and visibility per mesh block id.
        final xml = utf8.decode(payload, allowMalformed: true);
        final objectRe = RegExp(r'<MeshSO\d*>(.*?)</MeshSO\d*>', dotAll: true);
        for (final m in objectRe.allMatches(xml)) {
          final body = m.group(1) ?? '';
          final file = RegExp(r'<Filename>(.*?)</Filename>').firstMatch(body);
          final block =
              RegExp(r'<MeshBlockID>(\d+)</MeshBlockID>').firstMatch(body);
          final vis =
              RegExp(r'<Visibility>(\d+)</Visibility>').firstMatch(body);
          if (block == null) continue;
          final id = int.parse(block.group(1)!);
          if (vis != null && vis.group(1) == '0') continue;
          names[id] = file?.group(1) ?? 'Object $id';
        }
      } else {
        final obj = _readMeshBlock(payload);
        if (obj != null) {
          final id = nextBlock++;
          meshes
              .add(MixObject(name: names[id] ?? 'Object $id', mesh: obj.mesh));
        }
      }
    }
    return meshes;
  }

  /// Writes one scene object. Multiple objects are written as separate MMGS
  /// blocks with matching MeshSO9 records.
  static Uint8List write(List<MixObject> objects) {
    final usable = objects.where((o) => o.mesh.faceCount > 0).toList();
    if (usable.isEmpty) return Uint8List(0);

    final xml = StringBuffer();
    xml.write('<?xml version="1.0"?>\n');
    xml.write('<SceneObjects>\n');
    xml.write('\t<RecordID>112</RecordID>\n');
    xml.write('\t<RecordType>SceneObjects</RecordType>\n');
    xml.write('\t<Values>\n');
    xml.write('\t\t<WorldUnits>millimeters</WorldUnits>\n');
    xml.write('\t\t<WorldUnitsScale>1</WorldUnitsScale>\n');
    xml.write(
        '\t\t<SceneTransform>1 0 0 0 1 0 0 0 1 0 0 0 1 1 1 0 0 0 0 0 0</SceneTransform>\n');
    xml.write('\t\t<WorldUnitIncrement>10</WorldUnitIncrement>\n');
    xml.write('\t\t<MeshSO9>MeshSO</MeshSO9>\n');
    xml.write('\t</Values>\n');
    xml.write('\t<SubRecords />\n');
    xml.write('</SceneObjects>\n');

    for (var i = 0; i < usable.length; i++) {
      final name = _xmlEscape(usable[i].name);
      final codes = name.codeUnits.map((c) => '$c,').join();
      xml.write('<MeshSO9>\n');
      xml.write('\t<RecordID>${113 + i}</RecordID>\n');
      xml.write('\t<RecordType>MeshSO9</RecordType>\n');
      xml.write('\t<Values>\n');
      xml.write('\t\t<SceneObjectID>${9 + i}</SceneObjectID>\n');
      xml.write('\t\t<SceneObjectUUID>${_uuid()}</SceneObjectUUID>\n');
      xml.write('\t\t<SceneObjectStringID>$codes</SceneObjectStringID>\n');
      xml.write('\t\t<Visibility>1</Visibility>\n');
      xml.write('\t\t<Filename>$name</Filename>\n');
      xml.write('\t\t<MeshBlockID>${i + 1}</MeshBlockID>\n');
      xml.write(
          '\t\t<FileTransform>1 0 0 0 1 0 0 0 1 0 0 0 1 1 1 0 0 0 0 0 0</FileTransform>\n');
      xml.write(
          '\t\t<LocalFrame>1 0 0 0 1 0 0 0 1 1 0 0 0 1 0 0 0 1 0 0 0 </LocalFrame>\n');
      xml.write('\t</Values>\n');
      xml.write('\t<SubRecords />\n');
      xml.write('</MeshSO9>\n');
    }

    xml.write('<SemanticDB>\n');
    xml.write('\t<RecordID>${113 + usable.length}</RecordID>\n');
    xml.write('\t<RecordType>SemanticDB</RecordType>\n');
    xml.write('\t<Values>\n');
    xml.write('\t\t<BinaryBlockID>${usable.length + 1}</BinaryBlockID>\n');
    xml.write('\t</Values>\n');
    xml.write('\t<SubRecords />\n');
    xml.write('</SemanticDB>\n');
    xml.write('<DataStoreVersion>\n');
    xml.write('\t<RecordID>${114 + usable.length}</RecordID>\n');
    xml.write('\t<RecordType>DataStoreVersion</RecordType>\n');
    xml.write('\t<Values>\n');
    xml.write('\t\t<Version>meshmixer 3</Version>\n');
    xml.write('\t</Values>\n');
    xml.write('\t<SubRecords />\n');
    xml.write('</DataStoreVersion>');

    final blocks = usable.map((o) => _meshBlock(o.mesh)).toList();
    final index = BytesBuilder();
    _writeU32(index, blocks.length + 1);
    for (var i = 0; i < blocks.length; i++) {
      _writeU32(index, i + 1);
      _writeU32(index, blocks[i].length);
    }
    _writeU32(index, usable.length + 1);
    _writeU32(index, _semanticBlock.length);

    final out = BytesBuilder();
    void record(List<int> payload) {
      _writeU32(out, payload.length);
      out.add(payload);
    }

    record(utf8.encode(xml.toString()));
    record(index.toBytes());
    for (final b in blocks) {
      record(b);
    }
    record(_semanticBlock);
    return out.toBytes();
  }

  static Uint8List _meshBlock(TriMesh mesh) {
    mesh.requireUntextured('MIX export');
    if (mesh.validate().isNotEmpty ||
        mesh.vertexCount > 2000000 ||
        mesh.faceCount > 4000000) {
      throw const FormatException('Invalid or oversized MIX geometry');
    }
    final nv = mesh.vertexCount;
    final nf = mesh.faceCount;
    final normals = Float32List(nv * 3);
    for (var f = 0; f < nf; f++) {
      final ia = mesh.indices[f * 3],
          ib = mesh.indices[f * 3 + 1],
          ic = mesh.indices[f * 3 + 2];
      final ax = mesh.vx(ia), ay = mesh.vy(ia), az = mesh.vz(ia);
      final ux = mesh.vx(ib) - ax, uy = mesh.vy(ib) - ay, uz = mesh.vz(ib) - az;
      final wx = mesh.vx(ic) - ax, wy = mesh.vy(ic) - ay, wz = mesh.vz(ic) - az;
      final nx = uy * wz - uz * wy,
          ny = uz * wx - ux * wz,
          nz = ux * wy - uy * wx;
      for (final v in <int>[ia, ib, ic]) {
        normals[v * 3] += nx;
        normals[v * 3 + 1] += ny;
        normals[v * 3 + 2] += nz;
      }
    }
    for (var v = 0; v < nv; v++) {
      final l = math.sqrt(normals[v * 3] * normals[v * 3] +
          normals[v * 3 + 1] * normals[v * 3 + 1] +
          normals[v * 3 + 2] * normals[v * 3 + 2]);
      if (l > 1e-12) {
        normals[v * 3] /= l;
        normals[v * 3 + 1] /= l;
        normals[v * 3 + 2] /= l;
      } else {
        normals[v * 3 + 2] = 1;
      }
    }

    final out = BytesBuilder();
    _writeU32(out, 5);
    out.add(const <int>[0x4d, 0x4d, 0x47, 0x53, 0x00]); // MMGS\0
    _writeU32(out, 12);
    out.add(utf8.encode('GSurf 01.01\x00'));
    _writeU32(out, 11);
    out.add(utf8.encode('VFMesh 1.3\x00'));
    _writeU32(out, nv);
    _writeU32(out, nv);
    _writeU32(out, nf);
    _writeU32(out, nf);
    _writeU32(out, _vertexPayload);
    _writeU32(out, _facePayload);

    final vb = ByteData(_vertexRecordSize);
    for (var v = 0; v < nv; v++) {
      vb.setUint32(0, 56, Endian.little);
      vb.setUint32(4, v, Endian.little);
      vb.setFloat32(8, mesh.vx(v), Endian.little);
      vb.setFloat32(12, mesh.vy(v), Endian.little);
      vb.setFloat32(16, mesh.vz(v), Endian.little);
      vb.setFloat32(20, normals[v * 3], Endian.little);
      vb.setFloat32(24, normals[v * 3 + 1], Endian.little);
      vb.setFloat32(28, normals[v * 3 + 2], Endian.little);
      vb.setUint32(32, nv, Endian.little);
      vb.setUint32(36, 0, Endian.little);
      vb.setFloat32(40, 1, Endian.little);
      vb.setFloat32(44, 1, Endian.little);
      vb.setFloat32(48, 1, Endian.little);
      vb.setFloat32(52, 1, Endian.little);
      vb.setUint32(56, 0, Endian.little);
      out.add(vb.buffer.asUint8List());
    }

    final fb = ByteData(_faceRecordSize);
    for (var f = 0; f < nf; f++) {
      fb.setUint32(0, 24, Endian.little);
      fb.setUint32(4, f, Endian.little);
      fb.setUint32(8, mesh.indices[f * 3], Endian.little);
      fb.setUint32(12, mesh.indices[f * 3 + 1], Endian.little);
      fb.setUint32(16, mesh.indices[f * 3 + 2], Endian.little);
      fb.setUint32(
          20, mesh.faceGroups == null ? 0 : mesh.faceGroups![f], Endian.little);
      fb.setUint32(24, 0xFFFFFFFF, Endian.little);
      out.add(fb.buffer.asUint8List());
    }
    out.add(_polygonTrailer);
    return out.toBytes();
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _uuid() {
    final r = math.Random();
    String hex(int n) => n.toRadixString(16).padLeft(4, '0');
    return '${hex(r.nextInt(65536))}${hex(r.nextInt(65536))}-'
        '${hex(r.nextInt(65536))}-${hex(r.nextInt(65536))}-'
        '${hex(r.nextInt(65536))}-'
        '${hex(r.nextInt(65536))}${hex(r.nextInt(65536))}${hex(r.nextInt(65536))}';
  }

  static void _writeU32(BytesBuilder out, int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  static int _u32(Uint8List b, int o) {
    if (o < 0 || o > b.length - 4) {
      throw const FormatException('Truncated MIX value');
    }
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  }

  static double _f32(Uint8List b, int o) {
    if (o < 0 || o > b.length - 4) {
      throw const FormatException('Truncated MIX coordinate');
    }
    return ByteData.sublistView(b, o, o + 4).getFloat32(0, Endian.little);
  }
}
