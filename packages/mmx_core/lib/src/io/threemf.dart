import 'dart:convert';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../scene/document.dart';
import '../tools/modify.dart';

import '../mesh/tri_mesh.dart';
import 'zip.dart';
import 'threemf_materials.dart';

/// 3MF (3D Manufacturing Format) import/export.
///
/// The shipped Meshmixer binary imports 3MF through the bundled lib3mf; this is
/// Supports core meshes, base colors and diffuse PNG/JPEG textures. Other
/// material/extension semantics reject explicitly; this is not full Materials
/// Extension conformance (composites, PBR and color gradients are unsupported).
class ThreeMfIO {
  static const String _contentTypes = '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Default Extension="jpg" ContentType="image/jpeg"/>
</Types>''';

  static const String _rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>''';

  /// [unit] is one of micron, millimeter, centimeter, inch, foot, meter.
  static Uint8List write(TriMesh mesh,
      {String unit = 'millimeter', String name = 'mmx'}) {
    if (!_units.containsKey(unit)) {
      throw const FormatException('Unsupported 3MF unit');
    }
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Invalid 3MF geometry');
    }
    final coordinateScale = _units[unit]!;
    final surface = ThreeMfSurfaceWriter(mesh);
    name = XmlText(name).toXmlString();
    final sb = StringBuffer();
    sb.write('<?xml version="1.0" encoding="UTF-8"?>\n');
    sb.write('<model unit="$unit" xml:lang="en-US" '
        'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:m="$materialNamespace"${surface.textures.isEmpty && mesh.vertexColors == null ? '' : ' requiredextensions="m"'}>\n');
    sb.write('  <metadata name="Title">$name</metadata>\n');
    sb.write('  <resources>\n');
    sb.write(surface.resources);
    sb.write('    <object id="1" type="model">\n');
    sb.write('      <mesh>\n        <vertices>\n');
    for (var i = 0; i < mesh.vertexCount; i++) {
      sb.write(
          '          <vertex x="${_f(mesh.vx(i) / coordinateScale)}" y="${_f(mesh.vy(i) / coordinateScale)}" '
          'z="${_f(mesh.vz(i) / coordinateScale)}"/>\n');
    }
    sb.write('        </vertices>\n        <triangles>\n');
    for (var f = 0; f < mesh.faceCount; f++) {
      sb.write('          <triangle v1="${mesh.indices[f * 3]}" '
          'v2="${mesh.indices[f * 3 + 1]}" v3="${mesh.indices[f * 3 + 2]}"${surface.triangle(f)}/>\n');
    }
    sb.write('        </triangles>\n      </mesh>\n    </object>\n');
    sb.write('  </resources>\n');
    sb.write('  <build>\n    <item objectid="1"/>\n  </build>\n</model>\n');

    return ZipArchive.write(<ZipEntry>[
      ZipEntry('[Content_Types].xml',
          Uint8List.fromList(utf8.encode(_contentTypes))),
      ZipEntry('_rels/.rels', Uint8List.fromList(utf8.encode(_rels))),
      ZipEntry(
          '3D/3dmodel.model', Uint8List.fromList(utf8.encode(sb.toString()))),
      ...surface.textures,
      if (surface.textures.isNotEmpty)
        ZipEntry(
            '3D/_rels/3dmodel.model.rels',
            Uint8List.fromList(utf8.encode(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${[
              for (var i = 0; i < surface.textures.length; i++)
                '<Relationship Target="/${surface.textures[i].name}" Id="tex$i" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dtexture"/>'
            ].join()}</Relationships>'))),
    ]);
  }

  static const _units = <String, double>{
    'micron': 0.001,
    'millimeter': 1,
    'centimeter': 10,
    'inch': 25.4,
    'foot': 304.8,
    'meter': 1000
  };

  static TriMesh read(Uint8List bytes) {
    final files = {for (final e in ZipArchive.read(bytes)) e.name: e.data};
    final relBytes = files['_rels/.rels'];
    if (relBytes == null) {
      throw const FormatException('Missing 3MF relationships');
    }
    final rels = XmlDocument.parse(utf8.decode(relBytes));
    final rel = rels.descendants
        .whereType<XmlElement>()
        .where((e) =>
            e.name.local == 'Relationship' &&
            (e.getAttribute('Type') ?? '').endsWith('/3dmodel'))
        .firstOrNull;
    if (rel == null || rel.getAttribute('TargetMode') == 'External') {
      throw const FormatException('Missing internal 3MF model');
    }
    final target = Uri.parse(rel.getAttribute('Target') ?? '')
        .normalizePath()
        .path
        .replaceFirst(RegExp(r'^/'), '');
    final payload = files[target];
    if (payload == null) {
      throw const FormatException('Missing 3MF model payload');
    }
    final root = XmlDocument.parse(utf8.decode(payload)).rootElement;
    if (root.name.local != 'model') {
      throw const FormatException('Unsupported 3MF model');
    }
    for (final prefix in (root.getAttribute('requiredextensions') ?? '')
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)) {
      final uri = root.attributes
          .where((a) => a.name.qualified == 'xmlns:$prefix')
          .firstOrNull
          ?.value;
      if (uri != materialNamespace) {
        throw const FormatException('Unsupported required 3MF extension');
      }
    }
    final scale = _units[root.getAttribute('unit') ?? 'millimeter'];
    if (scale == null) throw const FormatException('Unsupported 3MF units');
    Iterable<XmlElement> children(XmlElement e, String name) =>
        e.childElements.where((c) => c.name.local == name);
    XmlElement child(XmlElement e, String name) => children(e, name).single;
    int integer(XmlElement e, String key) {
      final n = int.tryParse(e.getAttribute(key) ?? '');
      if (n == null || n < 0) throw FormatException('Invalid 3MF $key');
      return n;
    }

    double number(XmlElement e, String key) {
      final n = double.tryParse(e.getAttribute(key) ?? '');
      if (n == null || !n.isFinite) throw FormatException('Invalid 3MF $key');
      return n;
    }

    Float64List transform(XmlElement e) {
      final text = e.getAttribute('transform');
      if (text == null) return identity4();
      final v = text.trim().split(RegExp(r'\s+')).map(double.parse).toList();
      if (v.length != 12 || v.any((n) => !n.isFinite)) {
        throw const FormatException('Invalid 3MF transform');
      }
      return Float64List.fromList([
        v[0],
        v[1],
        v[2],
        0,
        v[3],
        v[4],
        v[5],
        0,
        v[6],
        v[7],
        v[8],
        0,
        v[9],
        v[10],
        v[11],
        1
      ]);
    }

    try {
      final surfaceResources =
          ThreeMfMaterials(child(root, 'resources'), files);
      final resources = <int, XmlElement>{};
      for (final o in children(child(root, 'resources'), 'object')) {
        final id = integer(o, 'id');
        if (id == 0 || resources.containsKey(id)) {
          throw const FormatException('Duplicate 3MF object');
        }
        resources[id] = o;
      }
      var totalVertices = 0, totalFaces = 0, totalInstances = 0;
      TriMesh resolve(int id, Set<int> parents) {
        if (++totalInstances > 16384 ||
            parents.length > 64 ||
            parents.contains(id) ||
            !resources.containsKey(id)) {
          throw const FormatException('Invalid 3MF component graph');
        }
        final o = resources[id]!;
        final meshElement = children(o, 'mesh').firstOrNull;
        if (meshElement != null) {
          final builder = MeshBuilder();
          final surface = ThreeMfSurfaceBuilder(surfaceResources, o);
          for (final v in children(child(meshElement, 'vertices'), 'vertex')) {
            if (++totalVertices > 2000000) {
              throw const FormatException('3MF instance vertex limit exceeded');
            }
            builder.addVertex(number(v, 'x'), number(v, 'y'), number(v, 'z'));
          }
          for (final t
              in children(child(meshElement, 'triangles'), 'triangle')) {
            if (++totalFaces > 4000000) {
              throw const FormatException('3MF face limit exceeded');
            }
            final a = integer(t, 'v1'),
                b = integer(t, 'v2'),
                c = integer(t, 'v3');
            if (a >= builder.vertexCount ||
                b >= builder.vertexCount ||
                c >= builder.vertexCount) {
              throw const FormatException('Invalid 3MF triangle index');
            }
            surface.add(t, [a, b, c]);
            builder.addTriangle(a, b, c);
          }
          return surface.finish(builder.build());
        }
        if (o.getAttribute('pid') != null || o.getAttribute('pindex') != null) {
          throw const FormatException(
              '3MF component material overrides unsupported');
        }
        return Modify.combine(
            children(child(o, 'components'), 'component').map((c) {
          final mesh = resolve(integer(c, 'objectid'), {...parents, id});
          mesh.transform(transform(c));
          return mesh;
        }).toList());
      }

      final meshes = children(child(root, 'build'), 'item')
          .where((i) => i.getAttribute('printable') != '0')
          .map((i) {
        final mesh = resolve(integer(i, 'objectid'), {});
        mesh.transform(multiply4(scale4(scale), transform(i)));
        return mesh;
      }).toList();
      final mesh = Modify.combine(meshes);
      if (mesh.validate().isNotEmpty) {
        throw const FormatException('Invalid 3MF geometry');
      }
      return mesh;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed 3MF structure');
    }
  }

  // Double text round-trips the float32 source without a fixed six-decimal
  // cutoff (which collapsed valid micron-scale geometry).
  static String _f(double v) => v.toString();
}
