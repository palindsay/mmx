import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../mesh/tri_mesh.dart';

/// Hash the consumed geometry and attributes, including decoded material data.
/// OBJ companion changes therefore change this hash even if the OBJ is unchanged.
Future<String> meshFingerprint(TriMesh mesh) async {
  Uint8List bytes(TypedData data) =>
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final buffers = <List<int>>[
    utf8.encode(jsonEncode({
      'vertices': mesh.vertexCount,
      'faces': mesh.faceCount,
      'groups': mesh.faceGroups != null,
      'colors': mesh.vertexColors != null,
      'uvs': mesh.cornerUvs != null,
      'faceMaterials': mesh.faceMaterials != null
    })),
    bytes(mesh.positions),
    bytes(mesh.indices),
    if (mesh.faceGroups != null) bytes(mesh.faceGroups!),
    if (mesh.vertexColors != null) bytes(mesh.vertexColors!),
    if (mesh.cornerUvs != null) bytes(mesh.cornerUvs!),
    if (mesh.faceMaterials != null) bytes(mesh.faceMaterials!),
    for (final material in mesh.materials) ...[
      utf8.encode(jsonEncode({
        'name': material.name,
        'color': material.baseColor,
        'clamp': material.textureClamp,
        'texture': material.texture == null
            ? null
            : {
                'width': material.texture!.width,
                'height': material.texture!.height,
                'mime': material.texture!.mimeType
              }
      })),
      if (material.texture != null) material.texture!.bytes,
    ],
  ];
  return (await sha256.bind(Stream<List<int>>.fromIterable(buffers)).first)
      .toString();
}
