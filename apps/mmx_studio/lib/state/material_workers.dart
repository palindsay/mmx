import 'dart:io';
import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';

import 'worker_runtime.dart';

/// Bounded texture IO and UV/mesh allocation run outside the UI isolate.
Future<TriMesh> applyMaterialWorker(
  TriMesh source,
  List<double> baseColor, {
  String? texturePath,
  bool removeTexture = false,
  int? planarAxis,
  bool textureClamp = false,
}) => executeWorker(() {
  var mesh = source.clone();
  if (planarAxis != null) mesh = Unwrap.planar(mesh, axis: planarAxis).mesh;
  var texture = removeTexture ? null : source.materials.firstOrNull?.texture;
  if (texturePath != null) {
    final file = File(texturePath);
    final handle = file.openSync();
    late Uint8List bytes;
    try {
      final size = handle.lengthSync();
      if (size <= 0 || size > MeshTexture.maxEncodedBytes) {
        throw const FormatException(
          'Texture must be a PNG/JPEG no larger than 16 MiB',
        );
      }
      bytes = handle.readSync(size);
      if (bytes.length != size || handle.readByteSync() != -1) {
        throw const FormatException(
          'Texture changed while being read; choose it again',
        );
      }
    } finally {
      handle.closeSync();
    }
    texture = TextureIO.decode(bytes, name: file.uri.pathSegments.last);
  }
  if (texture != null && mesh.cornerUvs == null) {
    throw const FormatException(
      'A texture needs UV coordinates. Choose a planar UV mapping before applying it.',
    );
  }
  mesh.materials = [
    MeshMaterial(
      name: source.materials.firstOrNull?.name ?? 'Studio material',
      baseColor: baseColor,
      texture: texture,
      textureClamp: textureClamp,
    ),
  ];
  mesh.faceMaterials = Uint16List(mesh.faceCount);
  return mesh;
});

Future<TriMesh> removeSurfaceAttributesWorker(TriMesh source) => executeWorker(
  () => source.clone()
    ..cornerUvs = null
    ..faceMaterials = null
    ..materials = [],
);
