import 'dart:convert';
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';
import '../scan/workflow.dart';
import '../scene/document.dart';
import '../tools/pivot.dart';
import '../render/camera.dart';
import 'zip.dart';
import '../mesh/material.dart';
import 'texture.dart';

/// Original import data retained independently of editable geometry. In
/// particular, opaque .mix records remain recoverable after project edits.
class ProjectSourceAttachment {
  final String name;
  final Uint8List bytes;
  ProjectSourceAttachment({required this.name, required this.bytes});
}

/// Native, versioned editing document. Geometry is stored little-endian.
class ProjectData {
  final List<SceneObject> objects;
  final Camera camera;
  final PrintProfile printProfile;
  final int? selectedId;
  final List<ProjectSourceAttachment> sourceAttachments;
  ProjectData(this.objects,
      {Camera? camera,
      this.selectedId,
      this.sourceAttachments = const [],
      this.printProfile = const PrintProfile()})
      : camera = camera ?? Camera();
}

class ProjectIO {
  /// Conservative, allocation-bounded admission check for editable documents.
  /// Leave room under the 256 MiB archive limit for JSON and ZIP framing.
  static void checkBudget(ProjectData project) {
    var bytes = 0, metadata = 0, entries = 1;
    final textures = <MeshTexture>{};
    if (project.objects.length > 1024 ||
        project.sourceAttachments.length > 1024) {
      throw const FormatException('Project object/source limit exceeded');
    }
    for (final object in project.objects) {
      final mesh = object.mesh;
      metadata += 4096 + object.name.length * 6;
      metadata += object.scanHistory
          .fold<int>(0, (n, entry) => n + entry.length * 6 + 8);
      for (final buffer in <TypedData?>[
        mesh.positions,
        mesh.indices,
        mesh.faceGroups,
        mesh.vertexColors,
        mesh.cornerUvs,
        mesh.faceMaterials
      ]) {
        if (buffer != null) {
          bytes += buffer.lengthInBytes;
          entries++;
        }
      }
      for (final material in mesh.materials) {
        metadata += 1024 +
            material.name.length * 6 +
            (material.texture?.name.length ?? 0) * 6;
        if (material.texture != null) textures.add(material.texture!);
      }
    }
    for (final source in project.sourceAttachments) {
      metadata += 256 + source.name.length * 6;
      bytes += source.bytes.length;
      entries++;
    }
    for (final texture in textures) {
      bytes += texture.bytes.length;
      entries++;
    }
    if (entries > 4096 ||
        bytes > 240 * 1024 * 1024 ||
        metadata > 8 * 1024 * 1024 ||
        textures.fold<int>(0, (n, t) => n + t.byteSize) > 192 * 1024 * 1024) {
      throw const FormatException(
          'Project exceeds the supported save budget. Reduce the scene or use separate projects.');
    }
  }

  static void _validateCamera(Camera camera) {
    if (camera.target.length != 3 ||
        ![
          camera.yaw,
          camera.pitch,
          camera.distance,
          camera.fovDegrees,
          camera.near,
          camera.far,
          ...camera.target
        ].every((v) => v.isFinite) ||
        camera.distance <= 0 ||
        camera.near <= 0 ||
        camera.far <= camera.near ||
        camera.fovDegrees <= 0 ||
        camera.fovDegrees >= 180) {
      throw const FormatException('Invalid camera');
    }
    // Finite input scalars alone do not guarantee usable camera arithmetic:
    // tiny FOVs and near-plane gaps can overflow, huge targets can erase the
    // eye offset, and projection depth can underflow to a singular matrix.
    final eye = camera.position();
    final view = camera.viewMatrix();
    final projection = camera.projectionMatrix(1);
    final combined = camera.viewProjection(1);
    final basisDeterminant =
        view[0] * (view[5] * view[10] - view[9] * view[6]) -
            view[4] * (view[1] * view[10] - view[9] * view[2]) +
            view[8] * (view[1] * view[6] - view[5] * view[2]);
    if (![...eye, ...view, ...projection, ...combined]
            .every((v) => v.isFinite) ||
        Iterable<int>.generate(3).every((i) => eye[i] == camera.target[i]) ||
        basisDeterminant == 0 ||
        projection[0] <= 0 ||
        projection[5] <= 0 ||
        projection[14] == 0) {
      throw const FormatException('Numerically unusable camera');
    }
  }

  static Uint8List write(ProjectData project) {
    final entries = <ZipEntry>[];
    final objects = <Map<String, Object?>>[];
    final ids = <int>{};
    final texturePaths = <MeshTexture, String>{};
    final c = project.camera;
    if (project.objects.length > 1024 ||
        project.sourceAttachments.length > 1024) {
      throw const FormatException('Invalid project metadata');
    }
    _validateCamera(c);
    project.printProfile.validate();
    for (final o in project.objects) {
      if (o.id <= 0 ||
          !ids.add(o.id) ||
          o.name.length > 1048576 ||
          o.scanHistory.length > 10000 ||
          o.scanHistory.any((entry) => entry.length > 4096) ||
          (o.scanSourceId != null &&
              (o.scanSourceId == o.id ||
                  !project.objects
                      .any((candidate) => candidate.id == o.scanSourceId))) ||
          o.transform.length != 16 ||
          o.transform.any((v) => !v.isFinite) ||
          o.transform[3] != 0 ||
          o.transform[7] != 0 ||
          o.transform[11] != 0 ||
          o.transform[15] != 1 ||
          (o.pivot != null &&
              (o.pivot!.position.length != 3 ||
                  o.pivot!.normal.length != 3 ||
                  [...o.pivot!.position, ...o.pivot!.normal]
                      .any((v) => !v.isFinite)))) {
        throw const FormatException('Invalid project object metadata');
      }
      final errors = o.mesh.validate();
      if (errors.isNotEmpty) throw FormatException(errors.join(', '));
      String buffer(String name, List<num> values, int width, bool floating) {
        final data = ByteData(values.length * width);
        for (var i = 0; i < values.length; i++) {
          if (floating) {
            data.setFloat32(i * width, values[i].toDouble(), Endian.little);
          } else if (width == 2) {
            data.setUint16(i * width, values[i].toInt(), Endian.little);
          } else {
            data.setUint32(i * width, values[i].toInt(), Endian.little);
          }
        }
        final path = 'objects/${o.id}/$name';
        entries.add(ZipEntry(path, data.buffer.asUint8List()));
        return path;
      }

      objects.add({
        'id': o.id,
        'name': o.name,
        'transform': o.transform.toList(),
        'visible': o.visible,
        'target': o.isTarget,
        'locked': o.locked,
        'scanSourceId': o.scanSourceId,
        'scanHistory': o.scanHistory,
        'pivot': o.pivot == null
            ? null
            : {'position': o.pivot!.position, 'normal': o.pivot!.normal},
        'positions': buffer('positions', o.mesh.positions, 4, true),
        'indices': buffer('indices', o.mesh.indices, 4, false),
        'groups': o.mesh.faceGroups == null
            ? null
            : buffer('groups', o.mesh.faceGroups!, 2, false),
        'colors': o.mesh.vertexColors == null
            ? null
            : buffer('colors', o.mesh.vertexColors!, 4, true),
        'uvs': o.mesh.cornerUvs == null
            ? null
            : buffer('uvs', o.mesh.cornerUvs!, 4, true),
        'faceMaterials': o.mesh.faceMaterials == null
            ? null
            : buffer('faceMaterials', o.mesh.faceMaterials!, 2, false),
        'materials': [
          for (final material in o.mesh.materials)
            {
              'name': material.name,
              'baseColor': material.baseColor,
              'clamp': material.textureClamp,
              'texture': material.texture == null
                  ? null
                  : texturePaths.putIfAbsent(material.texture!, () {
                      TextureIO.validateSource(material.texture!);
                      final path = 'textures/${texturePaths.length}.bin';
                      entries.add(ZipEntry(path, material.texture!.bytes));
                      return path;
                    }),
              'textureName': material.texture?.name,
            }
        ],
      });
    }
    if (project.selectedId != null && !ids.contains(project.selectedId)) {
      throw const FormatException('Missing selected object');
    }
    if (texturePaths.keys.fold<int>(0, (n, t) => n + t.byteSize) >
        192 * 1024 * 1024) {
      throw const FormatException('Project texture budget exceeded');
    }
    final sources = <Map<String, String>>[];
    for (var i = 0; i < project.sourceAttachments.length; i++) {
      final source = project.sourceAttachments[i];
      if (source.name.length > 1048576) {
        throw const FormatException('Project source name exceeds limit');
      }
      final path = 'sources/$i.bin';
      sources.add({'name': source.name, 'path': path});
      entries.add(ZipEntry(path, source.bytes));
    }
    entries.insert(
        0,
        ZipEntry(
            'manifest.json',
            Uint8List.fromList(utf8.encode(jsonEncode({
              'version': 3,
              'units': 'millimeter',
              'printProfile': project.printProfile.toJson(),
              'objects': objects,
              'selectedId': project.selectedId,
              'sources': sources,
              'camera': {
                'yaw': c.yaw,
                'pitch': c.pitch,
                'distance': c.distance,
                'target': c.target,
                'fov': c.fovDegrees,
                'near': c.near,
                'far': c.far
              },
            })))));
    if (entries.length > 4096 ||
        entries.fold<int>(0, (n, e) => n + e.data.length) > 256 * 1024 * 1024) {
      throw const FormatException('Project exceeds archive limits');
    }
    final bytes = ZipArchive.write(entries);
    if (bytes.length > 256 * 1024 * 1024) {
      throw const FormatException('Project exceeds file limit');
    }
    return bytes;
  }

  static ProjectData read(Uint8List bytes) {
    try {
      final files = {for (final e in ZipArchive.read(bytes)) e.name: e.data};
      final m = jsonDecode(utf8.decode(files['manifest.json']!))
          as Map<String, dynamic>;
      if (![1, 2, 3].contains(m['version']) || m['units'] != 'millimeter') {
        throw const FormatException('Unsupported project version or units');
      }
      final objectRecords = m['objects'] as List;
      final sourceRecords = m['sources'] as List? ?? [];
      if (objectRecords.length > 1024 || sourceRecords.length > 1024) {
        throw const FormatException('Project record count exceeds limit');
      }
      List<double> vector(dynamic value, int length) {
        if (value is! List || value.length != length) {
          throw const FormatException('Invalid project vector');
        }
        final result = value.map((v) => (v as num).toDouble()).toList();
        if (result.any((v) => !v.isFinite)) {
          throw const FormatException('Invalid project vector');
        }
        return result;
      }

      final claimedBuffers = <String>{};
      List<num> buffer(dynamic path, int width, bool floating) {
        if (path is! String ||
            !path.startsWith('objects/') ||
            !claimedBuffers.add(path)) {
          throw const FormatException('Invalid or reused project buffer');
        }
        final bytes = files[path]!;
        if (bytes.length % width != 0) {
          throw const FormatException('Invalid buffer size');
        }
        final data = ByteData.sublistView(bytes);
        final List<num> values = floating
            ? Float32List(bytes.length ~/ width)
            : width == 2
                ? Uint16List(bytes.length ~/ width)
                : Uint32List(bytes.length ~/ width);
        for (var i = 0; i < values.length; i++) {
          values[i] = floating
              ? data.getFloat32(i * width, Endian.little)
              : width == 2
                  ? data.getUint16(i * width, Endian.little)
                  : data.getUint32(i * width, Endian.little);
        }
        return values;
      }

      final sources = <ProjectSourceAttachment>[];
      for (final source in sourceRecords) {
        final path = source['path'] as String;
        final name = source['name'] as String;
        if (!path.startsWith('sources/') ||
            !claimedBuffers.add(path) ||
            name.length > 1048576 ||
            files[path] == null) {
          throw const FormatException('Invalid project source attachment');
        }
        sources.add(ProjectSourceAttachment(name: name, bytes: files[path]!));
      }
      final ids = <int>{};
      final textures = <String, MeshTexture>{};
      var textureBudget = 0;
      MeshTexture? texture(dynamic path, dynamic name) {
        if (path == null) return null;
        if (path is! String || !path.startsWith('textures/')) {
          throw const FormatException('Invalid project texture path');
        }
        return textures.putIfAbsent(path, () {
          final image = TextureIO.decode(files[path]!,
              name: name as String,
              maxDecodedBytes: 192 * 1024 * 1024 - textureBudget);
          if ((textureBudget += image.byteSize) > 192 * 1024 * 1024) {
            throw const FormatException('Project texture budget exceeded');
          }
          return image;
        });
      }

      final objects = <SceneObject>[];
      for (final o in objectRecords) {
        final id = o['id'] as int;
        final name = o['name'] as String;
        if (id <= 0 || !ids.add(id) || name.length > 1048576) {
          throw const FormatException('Invalid project object metadata');
        }
        final materials = <MeshMaterial>[];
        final records = o['materials'] as List? ?? [];
        if (records.length > 4096) {
          throw const FormatException('Too many project materials');
        }
        for (final material in records) {
          materials.add(MeshMaterial(
              name: material['name'] as String,
              baseColor: vector(material['baseColor'], 4),
              textureClamp: material['clamp'] as bool,
              texture: texture(material['texture'], material['textureName'])));
        }
        final mesh = TriMesh(
            Float32List.fromList(
                buffer(o['positions'], 4, true).cast<double>()),
            Uint32List.fromList(buffer(o['indices'], 4, false).cast<int>()),
            faceGroups: o['groups'] == null
                ? null
                : Uint16List.fromList(
                    buffer(o['groups'], 2, false).cast<int>()),
            vertexColors: o['colors'] == null
                ? null
                : Float32List.fromList(
                    buffer(o['colors'], 4, true).cast<double>()),
            cornerUvs: o['uvs'] == null
                ? null
                : Float32List.fromList(
                    buffer(o['uvs'], 4, true).cast<double>()),
            faceMaterials: o['faceMaterials'] == null
                ? null
                : Uint16List.fromList(
                    buffer(o['faceMaterials'], 2, false).cast<int>()),
            materials: materials);
        if (mesh.validate().isNotEmpty) {
          throw FormatException(mesh.validate().join(', '));
        }
        final transform = vector(o['transform'], 16);
        if (transform[3] != 0 ||
            transform[7] != 0 ||
            transform[11] != 0 ||
            transform[15] != 1) {
          throw const FormatException('Invalid affine transform');
        }
        objects.add(SceneObject(id, name, mesh,
            transform: Float64List.fromList(transform))
          ..visible = o['visible'] as bool
          ..isTarget = o['target'] as bool
          ..locked = (o['locked'] ?? false) as bool
          ..scanSourceId = o['scanSourceId'] as int?
          ..scanHistory =
              List<String>.from(o['scanHistory'] ?? const <String>[])
          ..pivot = o['pivot'] == null
              ? null
              : Pivot(
                  position: vector(o['pivot']['position'], 3),
                  normal: vector(o['pivot']['normal'], 3)));
      }
      for (final object in objects) {
        if (object.scanHistory.length > 10000 ||
            object.scanHistory.any((entry) => entry.length > 4096) ||
            (object.scanSourceId != null &&
                (object.scanSourceId == object.id ||
                    !objects.any((o) => o.id == object.scanSourceId)))) {
          throw const FormatException('Invalid scan provenance');
        }
      }
      final c = m['camera'];
      final v = vector(
          [c['yaw'], c['pitch'], c['distance'], c['fov'], c['near'], c['far']],
          6);
      final camera = Camera(
          yaw: v[0],
          pitch: v[1],
          distance: v[2],
          fovDegrees: v[3],
          near: v[4],
          far: v[5],
          target: vector(c['target'], 3));
      _validateCamera(camera);
      final selected = m['selectedId'] as int?;
      if (selected != null && !ids.contains(selected)) {
        throw const FormatException('Missing selected object');
      }
      return ProjectData(objects,
          sourceAttachments: sources,
          selectedId: selected,
          printProfile: PrintProfile.fromJson(
              Map<String, dynamic>.from(m['printProfile'] ?? {})),
          camera: camera);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed project');
    }
  }
}
