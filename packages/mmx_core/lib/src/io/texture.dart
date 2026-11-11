import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../mesh/material.dart';

/// Bounded PNG/JPEG decoding. Embedded metadata is preserved in the original
/// bytes, but not executed or used as external resource references.
class TextureIO {
  static final _verifiedSources = Expando<bool>('verified texture source');

  /// Persistence stores encoded source bytes, so caller-supplied pixels must
  /// describe that same image. Immutable decoded textures need this check only
  /// once per isolate; rendering never performs an additional image decode.
  static void validateSource(MeshTexture texture) {
    if (_verifiedSources[texture] == true) return;
    final decoded = decode(texture.bytes, name: texture.name);
    if (decoded.mimeType != texture.mimeType ||
        decoded.width != texture.width ||
        decoded.height != texture.height ||
        Iterable<int>.generate(decoded.rgba.length)
            .any((i) => decoded.rgba[i] != texture.rgba[i])) {
      throw const FormatException(
          'Texture pixels or metadata do not match encoded source');
    }
    _verifiedSources[texture] = true;
  }

  static MeshTexture decode(Uint8List bytes,
      {String name = 'texture', int maxDecodedBytes = 192 * 1024 * 1024}) {
    if (bytes.isEmpty || bytes.length > MeshTexture.maxEncodedBytes) {
      throw const FormatException('Texture exceeds 16 MiB encoded limit');
    }
    try {
      final png = bytes.length >= 8 && bytes[0] == 137 && bytes[1] == 80;
      final jpeg = bytes.length >= 2 && bytes[0] == 255 && bytes[1] == 216;
      if (!png && !jpeg) {
        throw const FormatException('Only PNG/JPEG textures are supported');
      }
      final img.Decoder decoder = png
          ? img.PngDecoder(maxPixels: MeshTexture.maxPixels)
          : img.JpegDecoder(maxPixels: MeshTexture.maxPixels);
      final info = decoder.startDecode(png ? _pngPixelsOnly(bytes) : bytes);
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width > MeshTexture.maxDimension ||
          info.height > MeshTexture.maxDimension ||
          info.width * info.height > MeshTexture.maxPixels ||
          info.width * info.height * 4 + bytes.length > maxDecodedBytes ||
          info.numFrames > 1) {
        throw const FormatException('Invalid, animated or oversized texture');
      }
      final decoded = decoder.decodeFrame(0);
      if (decoded == null) {
        throw const FormatException('Invalid texture pixels');
      }
      final image = decoded.convert(format: img.Format.uint8, numChannels: 4);
      final texture = MeshTexture(
          name: name,
          mimeType: png ? 'image/png' : 'image/jpeg',
          width: image.width,
          height: image.height,
          bytes: bytes,
          rgba: image.getBytes(order: img.ChannelOrder.rgba));
      _verifiedSources[texture] = true;
      return texture;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed PNG/JPEG texture');
    }
  }

  // Drop ancillary compressed text/profile chunks before parsing: their
  // decompressed size is unrelated to pixel dimensions. Keep original bytes.
  static Uint8List _pngPixelsOnly(Uint8List bytes) {
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(bytes, 0, 8));
    final data = ByteData.sublistView(bytes);
    var offset = 8, chunks = 0;
    while (offset < bytes.length) {
      if (++chunks > 65536 || offset + 12 > bytes.length) {
        throw const FormatException('Truncated PNG chunk');
      }
      final length = data.getUint32(offset);
      if (length > bytes.length - offset - 12) {
        throw const FormatException('Invalid PNG chunk length');
      }
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      if (type == 'acTL') {
        throw const FormatException('Animated textures are unsupported');
      }
      if (['IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'].contains(type)) {
        out.add(Uint8List.sublistView(bytes, offset, offset + length + 12));
      } else if ((bytes[offset + 4] & 32) == 0) {
        throw const FormatException('Unsupported PNG critical chunk');
      }
      offset += length + 12;
      if (type == 'IEND') {
        if (offset != bytes.length) {
          throw const FormatException('Trailing PNG data');
        }
        return out.takeBytes();
      }
    }
    throw const FormatException('Missing PNG end chunk');
  }
}

/// Aggregate texture budget and deduplication across one import.
class TextureLibrary {
  final _textures = <String, MeshTexture>{};
  var _bytes = 0;
  MeshTexture load(String path, Uint8List Function(String) readAsset) =>
      _textures.putIfAbsent(path, () {
        final texture = TextureIO.decode(readAsset(path),
            name: path.split('/').last,
            maxDecodedBytes: 192 * 1024 * 1024 - _bytes);
        _bytes += texture.byteSize;
        return texture;
      });
}
