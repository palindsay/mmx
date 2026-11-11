import 'dart:convert';
import 'dart:typed_data';

// Original 2×2 RGBA PNG: red/green top row, blue/translucent white bottom.
Uint8List textureFixturePng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAE0lEQVR4nGP4z8DwHwyBNAikAABJLQlctLUqZgAAAABJRU5ErkJggg==',
);
