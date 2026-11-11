import 'dart:typed_data';

/// Immutable sRGB texture. Rows in [rgba] start at the top of the image;
/// mesh UVs use v-up. Encoded source bytes survive native project round trips.
class MeshTexture {
  static const maxDimension = 4096;
  static const maxPixels = 16777216;
  static const maxEncodedBytes = 16777216;
  final String name, mimeType;
  final int width, height;
  final Uint8List bytes, rgba;
  final bool hasTransparency;

  factory MeshTexture(
      {required String name,
      required String mimeType,
      required int width,
      required int height,
      required Uint8List bytes,
      required Uint8List rgba}) {
    if (name.length > 4096 ||
        !['image/png', 'image/jpeg'].contains(mimeType) ||
        width <= 0 ||
        height <= 0 ||
        width > maxDimension ||
        height > maxDimension ||
        width * height > maxPixels ||
        rgba.length != width * height * 4 ||
        bytes.isEmpty ||
        bytes.length > maxEncodedBytes) {
      throw const FormatException('Invalid or oversized mesh texture');
    }
    return MeshTexture._(
        name,
        mimeType,
        width,
        height,
        Uint8List.fromList(bytes).asUnmodifiableView(),
        Uint8List.fromList(rgba).asUnmodifiableView());
  }
  MeshTexture._(
      this.name, this.mimeType, this.width, this.height, this.bytes, this.rgba)
      : hasTransparency = _hasAlpha(rgba);

  static bool _hasAlpha(Uint8List rgba) {
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] != 255) return true;
    }
    return false;
  }

  int get byteSize => bytes.lengthInBytes + rgba.lengthInBytes;
}

/// Supported material semantics: sRGB diffuse RGBA and one color texture.
/// Specular/PBR layers, normal maps and texture transforms are not inferred.
class MeshMaterial {
  final String name;
  final List<double> baseColor;
  final MeshTexture? texture;
  final bool textureClamp;
  MeshMaterial(
      {this.name = 'material',
      List<double> baseColor = const [1, 1, 1, 1],
      this.texture,
      this.textureClamp = false})
      : baseColor = List<double>.unmodifiable(baseColor) {
    if (name.length > 4096 ||
        baseColor.length != 4 ||
        baseColor.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw const FormatException('Invalid mesh material');
    }
  }
  bool get hasTransparency =>
      baseColor[3] < 1 || (texture?.hasTransparency ?? false);
}
