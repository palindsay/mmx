import 'dart:convert';
import 'dart:typed_data';
import '../mesh/material.dart';
import 'asset_path.dart';
import 'texture.dart';

/// Diffuse Wavefront materials: Kd, d/Tr and one PNG/JPEG map_Kd.
/// Unsupported optical/texture operations fail instead of changing appearance.
class MtlIO {
  static Map<String, MeshMaterial> read(String text,
      {required Uint8List Function(String) readAsset,
      String directory = '',
      TextureLibrary? textures}) {
    textures ??= TextureLibrary();
    if (text.length > 4194304) throw const FormatException('MTL exceeds 4 MiB');
    final out = <String, MeshMaterial>{};
    String? name;
    var color = <double>[1, 1, 1, 1];
    MeshTexture? texture;
    var clamp = false;
    void finish() {
      if (name == null) return;
      if (out.length >= 4096 || out.containsKey(name)) {
        throw const FormatException('Duplicate or excessive MTL materials');
      }
      out[name] = MeshMaterial(
          name: name, baseColor: color, texture: texture, textureClamp: clamp);
    }

    for (final raw in LineSplitter.split(text)) {
      if (raw.length > 65536) {
        throw const FormatException('MTL line exceeds limit');
      }
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final fields = line.split(RegExp(r'\s+'));
      final key = fields.first;
      final value = line.substring(key.length).trim();
      if (key == 'newmtl') {
        finish();
        name = value;
        color = [1, 1, 1, 1];
        texture = null;
        clamp = false;
        if (name.isEmpty) throw const FormatException('Empty MTL name');
        continue;
      }
      if (name == null) {
        throw const FormatException('MTL property without material');
      }
      switch (key) {
        case 'Kd':
          if (fields.length != 4) {
            throw const FormatException('Expected RGB MTL diffuse color');
          }
          for (var i = 0; i < 3; i++) {
            color[i] = double.parse(fields[i + 1]);
          }
        case 'd':
        case 'Tr':
          if (fields.length != 2) {
            throw const FormatException('Unsupported MTL dissolve');
          }
          color[3] =
              key == 'Tr' ? 1 - double.parse(value) : double.parse(value);
        case 'map_Kd':
          var path = value;
          if (fields.length >= 4 && fields[1] == '-clamp') {
            if (!['on', 'off'].contains(fields[2])) {
              throw const FormatException('Invalid texture clamp');
            }
            clamp = fields[2] == 'on';
            path = fields.skip(3).join(' ');
          }
          if (path.startsWith('-') || texture != null) {
            throw const FormatException('Unsupported MTL texture options');
          }
          if (path.startsWith('"') && path.endsWith('"')) {
            path = path.substring(1, path.length - 1);
          }
          path = safeAssetPath('$directory${safeAssetPath(path)}');
          texture = textures.load(path, readAsset);
        case 'illum':
          if (!['0', '1', '2'].contains(value)) {
            throw const FormatException('Unsupported MTL illumination model');
          }
        case 'Ka':
        case 'Ks':
        case 'Ke':
          if (fields.length != 4 ||
              fields.skip(1).any((s) => double.tryParse(s) != 0)) {
            throw FormatException('Unsupported nonzero MTL $key');
          }
        case 'Ns':
          final n = double.tryParse(value);
          if (n == null || !n.isFinite || n < 0) {
            throw const FormatException('Invalid MTL shininess');
          }
        // Ks=0 is the only supported specular color; exponent has no effect.
        case 'Ni':
          if (double.tryParse(value) != 1) {
            throw const FormatException('MTL refraction is unsupported');
          }
        default:
          throw FormatException('Unsupported MTL property: $key');
      }
    }
    finish();
    return out;
  }
}
