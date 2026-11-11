/// Restrict companion resources to relative paths inside their source directory.
/// URI schemes, drive/UNC paths, traversal and control characters are rejected.
String safeAssetPath(String value) {
  final path = value.replaceAll('\\', '/');
  if (path.isEmpty ||
      path.length > 4096 ||
      path.startsWith('/') ||
      path.contains(':') ||
      path.runes.any((c) => c < 32) ||
      path.split('/').any((p) => p == '..' || p.isEmpty)) {
    throw FormatException('Unsafe companion asset path: $value');
  }
  return path.split('/').where((p) => p != '.').join('/');
}
