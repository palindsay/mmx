import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'workers.dart';
import 'spatial_cache.dart';
import '../render/desktop_renderer.dart';
import '../render/scene_render_worker.dart';
export '../render/desktop_renderer.dart' show RenderBackendPreference;
import 'manipulator.dart';
import 'material_workers.dart';
export 'manipulator.dart'
    show
        ManipulatorMode,
        ManipulatorSpace,
        ManipulatorScaleMode,
        ManipulatorSnap;
import 'worker_runtime.dart';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mmx_core/mmx_core.dart';

part 'scan_state.dart';

enum StudioTool {
  navigate,
  select,
  sculpt,
  stamp,
  planeCut,
  mirror,
  extrude,
  separate,
  remesh,
  reduce,
  makeSolid,
  hollow,
  supports,
  modify,
  analysis,
  print,
  scan,
}

enum AnalysisOverlay { none, thickness, overhang, stability, deviation }

/// Application state: document, camera, active tool parameters, viewport
/// image, and the operator plumbing that runs heavy kernels off the UI thread.
class StudioState extends ChangeNotifier {
  final Document doc = Document();
  Camera camera = Camera(yaw: 0.7, pitch: 0.3, distance: 3);
  StudioTool tool = StudioTool.navigate;
  AnalysisOverlay overlay = AnalysisOverlay.none;
  bool wireframe = false;
  bool showBed = true;
  bool busy = false;
  bool _disposed = false;
  String status = 'Ready';
  ScanReport? scanReport;
  int? scanReportRevision, scanReportObjectId;
  ScanPreview? scanPreview;
  bool scanPreviewShowOriginal = false;
  PrintProfile printProfile = const PrintProfile();
  double scanFragmentArea = 1, scanDisplacement = .1, scanDeviationLimit = .2;
  double scanEdgeLength = 1, scanKeepFraction = .5, printLayerHeight = .2;

  int? _selectedObjectId;
  int? get selectedObjectId => _selectedObjectId;
  set selectedObjectId(int? value) {
    if (_selectedObjectId == value || gestureActive || scanPreview != null) {
      return;
    }
    _spatialCache.clear();
    _selectedObjectId = value;
    selection = null;
    overlay = AnalysisOverlay.none;
    overlayColors = null;
  }

  final SceneSpatialCache _spatialCache = SceneSpatialCache();
  ManipulatorMode manipulatorMode = ManipulatorMode.none;
  ManipulatorSpace manipulatorSpace = ManipulatorSpace.world;
  ManipulatorScaleMode manipulatorScaleMode = ManipulatorScaleMode.axis;
  ManipulatorSnap manipulatorSnap = const ManipulatorSnap();
  ManipulatorGesture? _manipulator;
  bool _manipulatorEnding = false;
  bool get manipulatorGestureActive => _manipulator != null;

  int? _sculptGesture;
  int _nextSculptGesture = 0;
  int? _sculptSnapshotGesture;
  (double, double)? _pendingSculpt;
  Future<void>? _sculptDrain;
  void Function()? _sculptRollback;
  bool _sculptDirtyBefore = false;
  bool _strokeEnding = false;
  bool _strokeCancelRequested = false;
  Future<void>? _strokeCompletion;
  int? _sculptExpectedRevision;
  bool _sculptInterrupted = false;
  bool get gestureActive => _manipulator != null || _sculptGesture != null;
  bool get sculptGestureActive => _sculptGesture != null;
  bool get interactionLocked => busy || gestureActive;

  @visibleForTesting
  int get bvhBuildCount => _spatialCache.bvhBuilds;
  @visibleForTesting
  int get topologyBuildCount => _spatialCache.topologyBuilds;

  void setManipulatorMode(ManipulatorMode mode) {
    if (interactionLocked) return;
    manipulatorMode = mode;
    notify();
  }

  void setManipulatorSpace(ManipulatorSpace space) {
    if (interactionLocked) return;
    manipulatorSpace = space;
    notify();
  }

  void setManipulatorScaleMode(ManipulatorScaleMode mode) {
    if (interactionLocked) return;
    manipulatorScaleMode = mode;
    notify();
  }

  bool setManipulatorSnap(ManipulatorSnap snap) {
    if (interactionLocked || !snap.isValid) return false;
    manipulatorSnap = snap;
    notify();
    return true;
  }

  bool beginManipulator(int axis) {
    final obj = selected;
    if (_disposed ||
        interactionLocked ||
        obj == null ||
        obj.locked ||
        scanPreview != null ||
        manipulatorMode == ManipulatorMode.none ||
        axis < 0 ||
        axis > 2) {
      return false;
    }
    try {
      _manipulator = ManipulatorGesture(
        obj,
        manipulatorMode,
        axis,
        space: manipulatorSpace,
        scaleMode: manipulatorScaleMode,
        snap: manipulatorSnap,
      );
      notify();
      return true;
    } catch (e) {
      status = '$e';
      notify();
      return false;
    }
  }

  bool updateManipulator(double amount) {
    final gesture = _manipulator;
    if (_manipulatorEnding ||
        gesture == null ||
        doc.byId(gesture.object.id) != gesture.object) {
      return false;
    }
    try {
      final applied = gesture.preview(amount);
      _spatialCache.clear();
      status = '${gesture.mode.name}: ${applied.toStringAsFixed(3)}';
      _scheduleRender();
      return true;
    } catch (e) {
      status = '$e';
      notify();
      return false;
    }
  }

  /// Numeric edits use the identical captured-axis, snap, pivot and undo path.
  /// Rotation amounts use radians, and scale amounts use positive factors.
  Future<bool> applyManipulatorAmount(int axis, double amount) async {
    if (!amount.isFinite ||
        (manipulatorMode == ManipulatorMode.scale &&
            (amount < .01 || amount > 100))) {
      status =
          'Enter a finite amount; scale factors must be between 0.01 and 100';
      notify();
      return false;
    }
    if (!beginManipulator(axis)) return false;
    final accepted = updateManipulator(amount);
    final failure = status;
    await endManipulator(cancel: !accepted);
    if (!accepted) {
      status = failure;
      notify();
    }
    return accepted;
  }

  Future<void> endManipulator({bool cancel = false}) async {
    final gesture = _manipulator;
    if (gesture == null || _manipulatorEnding) return;
    _manipulatorEnding = true;
    try {
      if (doc.byId(gesture.object.id) != gesture.object) return;
      final transform = Float64List.fromList(gesture.object.transform);
      final pivot = gesture.object.pivot;
      gesture.restore();
      if (!cancel && gesture.changed) {
        doc.snapshot(
          gesture.mode == ManipulatorMode.pivot ? 'Move pivot' : 'Transform',
        );
        gesture.object.transform = transform;
        gesture.object.pivot = pivot;
        dirty = true;
      }
      _invalidateGeometry();
      status = cancel ? 'Transform cancelled' : 'Ready';
      if (!_disposed) {
        try {
          await render();
        } catch (e) {
          // The edit/cancellation is complete; a failed preview must release
          // the interaction lock and must not undo committed document data.
          status = 'Preview failed: $e';
        }
      }
    } finally {
      _manipulator = null;
      _manipulatorEnding = false;
      notify();
    }
  }

  bool beginSculptStroke() {
    if (_disposed ||
        interactionLocked ||
        selected == null ||
        selected!.locked ||
        scanPreview != null) {
      return false;
    }
    _sculptGesture = ++_nextSculptGesture;
    _sculptSnapshotGesture = null;
    _sculptRollback = doc.checkpoint();
    _sculptDirtyBefore = dirty;
    _strokeEnding = false;
    _strokeCancelRequested = false;
    _sculptInterrupted = false;
    _sculptExpectedRevision = doc.revision;
    return true;
  }

  Future<void> queueSculptSample(double x, double y) {
    if (_sculptGesture == null || _strokeEnding) return Future<void>.value();
    _pendingSculpt = (x, y);
    return _sculptDrain ??= _drainSculpt().whenComplete(() {
      _sculptDrain = null;
    });
  }

  Future<void> _drainSculpt() async {
    while (_pendingSculpt != null && _sculptGesture != null && !_disposed) {
      final point = _pendingSculpt!;
      _pendingSculpt = null;
      await sculptAt(point.$1, point.$2);
      if (_sculptInterrupted) {
        _pendingSculpt = null;
        break;
      }
    }
  }

  Future<void> endSculptStroke({bool cancel = false}) {
    if (_sculptGesture == null) return Future<void>.value();
    _strokeEnding = true;
    if (cancel) {
      _strokeCancelRequested = true;
      _pendingSculpt = null;
      cancelOperation();
    }
    return _strokeCompletion ??= _finishSculptStroke().whenComplete(() {
      _strokeCompletion = null;
    });
  }

  Future<void> _finishSculptStroke() async {
    await _sculptDrain;
    if (_strokeCancelRequested &&
        !_sculptInterrupted &&
        _sculptExpectedRevision == doc.revision) {
      _sculptRollback?.call();
      dirty = _sculptDirtyBefore;
    }
    _sculptGesture = null;
    _sculptRollback = null;
    _sculptSnapshotGesture = null;
    _sculptExpectedRevision = null;
    _invalidateGeometry();
    if (!_disposed) {
      await render();
      notify();
    }
  }

  Future<void> cancelInteraction() async {
    if (_manipulator != null) await endManipulator(cancel: true);
    if (_sculptGesture != null) {
      await endSculptStroke(cancel: true);
    } else {
      cancelOperation();
    }
  }

  final List<ProjectSourceAttachment> sourceAttachments = [];
  bool dirty = false;
  String? projectPath;
  int _operationId = 0;
  bool _cancelled = false;
  Future<Object?>? _activeWork;
  String? operationPhase;
  int _renderId = 0;
  int _sceneRenderEpoch = 0;
  String? operationWarning;

  void cancelOperation() {
    if (!busy) return;
    _cancelled = true;
    final work = _activeWork;
    if (work != null) cancelWorker(work);
    status = 'Cancelling…';
    notify();
  }

  Future<T> _work<T>(Future<T> computation) async {
    final id = _operationId;
    final revision = doc.revision;
    _activeWork = computation;
    operationPhase = 'Computing';
    notify();
    try {
      if (_disposed || _cancelled) cancelWorker(computation);
      final result = await computation;
      if (revision != doc.revision) {
        throw const _OperationCancelled(stale: true);
      }
      if (_disposed || _cancelled || id != _operationId) {
        throw const _OperationCancelled();
      }
      operationPhase = 'Applying result';
      return result;
    } on WorkerCancelled {
      throw _OperationCancelled(stale: revision != doc.revision);
    } finally {
      if (identical(_activeWork, computation)) _activeWork = null;
      operationPhase = null;
      notify();
    }
  }

  Future<bool> _perform(
    String label,
    Future<void> Function() action, {
    bool cleanOnSuccess = false,
  }) async {
    if (busy ||
        _disposed ||
        _manipulator != null ||
        (_sculptGesture != null && label != 'sculptAt')) {
      return false;
    }
    if (scanPreview != null && label != 'Apply scan preview') {
      status = 'Apply or cancel the scan preview first';
      notify();
      return false;
    }
    if (selected?.locked == true &&
        !const {
          'New project',
          'Save project',
          'Open project',
          'Scene metadata',
          'doDuplicate',
          'doAnalysis',
          'inspectMesh',
          'Scan inspection',
          'Compare scan',
          'Export scan data',
          'Slice report',
          'doMeasure',
          'doClearance',
          'exportSelected',
          'importPath',
          'addObject',
          'Pack',
        }.contains(label)) {
      status = 'Original scan is protected; duplicate it to make changes';
      notify();
      return false;
    }
    busy = true;
    _cancelled = false;
    _operationId++;
    final rollback = doc.checkpoint();
    final revision = doc.revision;
    final selectedId = selectedObjectId;
    final wasDirty = dirty;
    final sculptSnapshotBefore = _sculptSnapshotGesture;
    final cameraBefore = camera.clone();
    final pathBefore = projectPath;
    final profileBefore = printProfile;
    final sourcesBefore = List<ProjectSourceAttachment>.from(sourceAttachments);
    operationWarning = null;
    status = '$label…';
    notify();
    var succeeded = false;
    try {
      await action();
      if (doc.revision != revision) {
        ProjectIO.checkBudget(
          ProjectData(doc.objects, sourceAttachments: sourceAttachments),
        );
        dirty = true;
        _invalidateGeometry();
      }
      if (cleanOnSuccess) dirty = false;
      if (operationWarning != null) status += ' ($operationWarning)';
      succeeded = true;
    } catch (e) {
      if (label == 'sculptAt' && e is _OperationCancelled && e.stale) {
        _sculptInterrupted = true;
      }
      if (e is! _OperationCancelled || !e.stale) {
        rollback();
        selectedObjectId = selectedId;
        dirty = wasDirty;
        camera = cameraBefore;
        projectPath = pathBefore;
        printProfile = profileBefore;
        sourceAttachments
          ..clear()
          ..addAll(sourcesBefore);
        if (label == 'sculptAt' && _sculptGesture != null) {
          _sculptSnapshotGesture = sculptSnapshotBefore;
          _sculptExpectedRevision = doc.revision;
        }
      }
      _invalidateGeometry();
      status = e is _OperationCancelled
          ? '$label cancelled'
          : '$label failed: $e';
    } finally {
      // The transaction stays locked until its final preview settles. Finalize
      // dirty/path metadata before unlocking, including synchronous listeners
      // that start the next edit when they observe busy becoming false.
      final completionStatus = status;
      try {
        if (!_disposed) {
          operationPhase = 'Rendering preview';
          await render();
          status = completionStatus;
        }
      } catch (e) {
        // A committed edit or successful disk write remains successful when
        // only the preview fails. Open/import validate their preview inside the
        // action so an unreadable incoming scene can still be rolled back.
        status = '$completionStatus (Preview failed: $e)';
      } finally {
        operationPhase = null;
        busy = false;
        notify();
      }
    }
    return succeeded;
  }

  void _invalidateGeometry() {
    _sceneRenderEpoch++;
    scanPreview = null;
    scanReport = null;
    _spatialCache.clear();
    selection = null;
    overlay = AnalysisOverlay.none;
    overlayColors = null;
    if (selected == null) selectedObjectId = doc.objects.firstOrNull?.id;
    refreshShellCount();
  }

  int shellCount = 0;
  Selection? selection;
  Uint8List? overlayColors;

  ui.Image? frame;
  int frameWidth = 900;
  int frameHeight = 640;
  bool _renderQueued = false;
  int lastRenderMs = 0;
  RenderBackendPreference renderBackendPreference =
      RenderBackendPreference.auto;
  String renderBackend = 'Starting renderer';
  String renderDiagnostic = '';
  bool hardwareAccelerated = false;

  Future<void> setRenderBackend(RenderBackendPreference preference) async {
    if (_disposed || interactionLocked) return;
    renderBackendPreference = preference;
    try {
      await render();
    } catch (e) {
      status = 'Preview failed: $e';
      notify();
    }
  }

  // Tool parameters (mirrors Meshmixer panel ranges).
  double brushRadius = 8;
  double brushStrength = 0.5;
  BrushOp brushOp = BrushOp.draw;
  StampPattern stampPattern = StampPattern.circle;
  double stampRadius = 8;
  double stampHeight = 2;
  double remeshDensity = 0.5;
  double reducePercent = 0.5;
  double solidResolution = 128;
  SolidMode solidMode = SolidMode.accurate;
  double solidOffset = 0;
  int solidSmoothing = 0;
  double solidMinThickness = 0;
  double hollowThickness = 2;
  double hollowMinThickness = 0;
  int hollowHoles = 3;
  double supportAngle = 45;
  double supportDensity = 0.5;
  double thicknessThreshold = 1.0;
  double overhangAngle = 45;
  double planeOffset = 0;
  bool planeFill = true;
  bool planeKeepPositive = true;
  int planeAxis = 1;
  double mirrorPlaneOffset = 0;
  bool mirrorKeepOriginal = true;
  bool mirrorWeld = true;
  double extrudeDistance = 5;
  bool extrudeSmooth = true;
  int patternCountX = 3;
  int patternCountZ = 2;
  double patternGap = 2;
  PrimitiveKind primitiveKind = PrimitiveKind.box;
  bool remeshGroupAware = false;

  StudioState({bool loadStartup = false}) {
    if (loadStartup) _loadStartupModel();
  }

  SceneObject? get selected {
    final id = selectedObjectId;
    if (id == null) return null;
    return doc.byId(id);
  }

  TriMesh? get activeMesh => selected?.mesh;

  Future<void> _loadStartupModel() async {
    // Original procedural starter geometry; no third-party model redistribution.
    final bounds = TriMesh(
      Float32List.fromList([-12.5, -12.5, -12.5, 12.5, 12.5, 12.5]),
      Uint32List(0),
    );
    final mesh = Modify.fitPrimitive(bounds, PrimitiveKind.sphere);
    if (_disposed || busy || doc.objects.isNotEmpty) return;
    _install(mesh, 'Starter sphere');
    await render();
  }

  void _install(TriMesh mesh, String name) {
    final obj = doc.add(mesh, name: name);
    selectedObjectId = obj.id;
    _frameObject(obj);
    status = 'Loaded ${obj.name}: ${mesh.faceCount} faces';
  }

  void _frameObject(SceneObject obj) {
    final b = obj.worldBounds();
    if (b.isEmpty) return;
    camera.frame(b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ);
  }

  /// Start an untitled, empty document after the UI resolves unsaved changes.
  /// A new project is a document boundary: undo cannot restore the old project.
  Future<bool> newProject() => _perform('New project', () async {
    doc.replaceObjects([]);
    sourceAttachments.clear();
    printProfile = const PrintProfile();
    projectPath = null;
    selectedObjectId = null;
    camera = Camera(yaw: 0.7, pitch: 0.3, distance: 3);
    tool = StudioTool.navigate;
    manipulatorMode = ManipulatorMode.none;
    _invalidateGeometry();
    // Never show the previous project's image if the empty preview fails.
    _renderId++;
    frame?.dispose();
    frame = null;
    lastRenderMs = 0;
    status = 'New project — import a mesh to begin';
  }, cleanOnSuccess: true);

  Future<bool> saveProject(String path) async {
    if (interactionLocked || _disposed) return false;
    return _perform('Save project', () async {
      final savedRevision = doc.revision;
      final project = ProjectData(
        doc.objects.map((o) => o.clone()).toList(),
        camera: camera.clone(),
        selectedId: selectedObjectId,
        sourceAttachments: List.of(sourceAttachments),
        printProfile: printProfile,
      );
      final bytes = await _work(encodeProjectWorker(project));
      await writeFileAtomically(path, bytes);
      if (doc.revision != savedRevision) {
        throw const _OperationCancelled(stale: true);
      }
      projectPath = path;
      status = 'Saved $path';
    }, cleanOnSuccess: true);
  }

  Future<bool> openProject(String path, {bool asRecovery = false}) async {
    if (interactionLocked || _disposed) return false;
    return _perform('Open project', () async {
      final project = await _work(decodeProjectWorker(path));
      doc.replaceObjects(project.objects);
      sourceAttachments
        ..clear()
        ..addAll(project.sourceAttachments);
      camera = project.camera;
      printProfile = project.printProfile;
      selectedObjectId = project.selectedId;
      projectPath = asRecovery ? null : path;
      // Presentation of incoming data is part of accepting an open: retain the
      // previous unsaved document/history when a loaded camera cannot render.
      final appliedRevision = doc.revision;
      await render();
      if (doc.revision != appliedRevision) {
        throw const _OperationCancelled(stale: true);
      }
      if (_disposed || _cancelled) throw const _OperationCancelled();
      status = 'Opened $path';
    }, cleanOnSuccess: !asRecovery);
  }

  Future<void> autosave(String path) async {
    if (!dirty || interactionLocked || _disposed) return;
    final revision = doc.revision;
    final project = ProjectData(
      doc.objects.map((o) => o.clone()).toList(),
      camera: camera.clone(),
      selectedId: selectedObjectId,
      sourceAttachments: List.of(sourceAttachments),
      printProfile: printProfile,
    );
    final bytes = await encodeProjectWorker(project);
    if (!_disposed && revision == doc.revision && dirty) {
      await writeFileAtomically(path, bytes);
    }
  }

  Future<void> doBoolean(
    int otherId,
    BooleanOp op, {
    bool precise = true,
  }) async {
    final obj = selected, other = doc.byId(otherId);
    if (obj == null || other == null || obj.id == other.id) return;
    final a = obj.worldMesh(), b = other.worldMesh();
    final resolution = solidResolution.toInt();
    await runOp('Boolean ${op.name}', () async {
      final result = await _work(booleanWorker(a, b, op, precise, resolution));
      operationWarning = result.fallbackReason;
      return result.mesh;
    }, worldSpace: true);
  }

  /// Apply one whole-object material and optional UV projection atomically.
  Future<bool> applySelectedMaterial({
    required List<double> baseColor,
    String? texturePath,
    bool removeTexture = false,
    int? planarAxis,
    bool textureClamp = false,
  }) async {
    final object = selected;
    if (object == null || interactionLocked || _disposed) return false;
    final color = List<double>.from(baseColor);
    return _perform('Apply material', () async {
      final mesh = await _work(
        applyMaterialWorker(
          object.mesh,
          color,
          texturePath: texturePath,
          removeTexture: removeTexture,
          planarAxis: planarAxis,
          textureClamp: textureClamp,
        ),
      );
      if (doc.byId(object.id) != object) {
        throw const _OperationCancelled(stale: true);
      }
      doc.snapshot('Apply material');
      object.mesh = mesh;
      status = 'Material applied to ${object.name}';
    });
  }

  Future<bool> removeSelectedSurfaceAttributes() async {
    final object = selected;
    if (object == null ||
        interactionLocked ||
        _disposed ||
        !object.mesh.hasSurfaceAttributes) {
      return false;
    }
    return _perform('Remove materials and UVs', () async {
      final mesh = await _work(removeSurfaceAttributesWorker(object.mesh));
      if (doc.byId(object.id) != object) {
        throw const _OperationCancelled(stale: true);
      }
      doc.snapshot('Remove materials and UVs');
      object.mesh = mesh;
      status = 'Removed materials and UVs from ${object.name}';
    });
  }

  Future<void> transformSelected(Float64List transform) =>
      _perform('Transform', () async {
        final obj = selected;
        if (obj == null) return;
        if (transform.length != 16 || transform.any((v) => !v.isFinite)) {
          throw const FormatException('Invalid transform');
        }
        doc.snapshot('Transform');
        obj.transform = multiply4(transform, obj.transform);
        status = 'Transformed ${obj.name}';
      });

  Future<void> packAll() => _perform('Pack', () async {
    final objects = doc.objects.where((o) => o.visible && !o.locked).toList();
    final meshes = objects.map((o) => o.worldMesh()).toList();
    final result = await _work(packWorker(meshes, profile: printProfile));
    doc.snapshot('Pack');
    for (final p in result.placed) {
      objects[p.index].transform = multiply4(
        Float64List.fromList(p.transform),
        objects[p.index].transform,
      );
    }
    status =
        'Packed ${result.placed.length} objects; ${result.unplaced.length} unplaced${result.unplaced.isEmpty ? '' : ': ${result.unplaced.map((i) => objects[i].name).join(', ')}'}';
  });

  // ---------------------------------------------------------------- camera
  void orbit(double dx, double dy) {
    camera.orbit(-dx * 0.006, dy * 0.006);
    _scheduleRender(cameraOnly: true);
  }

  void pan(double dx, double dy) {
    camera.pan(dx, dy);
    _scheduleRender(cameraOnly: true);
  }

  void zoom(double delta) {
    camera.zoom(delta > 0 ? 0.92 : 1.08);
    _scheduleRender(cameraOnly: true);
  }

  void frameSelection() {
    final obj = selected;
    if (obj == null) return;
    _frameObject(obj);
    _scheduleRender(cameraOnly: true);
  }

  // ----------------------------------------------------------------- render
  void _scheduleRender({bool cameraOnly = false}) {
    _pendingSceneUpdate = _pendingSceneUpdate || !cameraOnly;
    if (_renderQueued) return;
    _renderQueued = true;
    Future<void>.microtask(() async {
      _renderQueued = false;
      _cameraRequest = !_pendingSceneUpdate;
      _pendingSceneUpdate = false;
      try {
        await render();
      } catch (e) {
        if (!_disposed) {
          status = 'Preview failed: $e';
          notify();
        }
      }
    });
  }

  final _sceneRenderer = SceneRenderWorker();
  bool _cameraRequest = false, _pendingSceneUpdate = false;
  Future<void>? _renderTask;
  Future<void> render() {
    if (!_cameraRequest) _sceneRenderEpoch++;
    _cameraRequest = false;
    _renderId++;
    return _renderTask ??= _renderLoop().whenComplete(() {
      _renderTask = null;
    });
  }

  Future<void> _renderLoop() async {
    while (!_disposed) {
      final id = _renderId;
      try {
        await _renderFrame(id);
      } catch (_) {
        if (!_disposed) rethrow;
      }
      if (id == _renderId) break;
    }
  }

  int? _renderObjectsEpoch;
  List<RenderObject> _renderObjects = [];

  Future<void> _renderFrame(int id) async {
    final sceneEpoch = _sceneRenderEpoch;
    final revision = doc.revision;
    if (_renderObjectsEpoch != sceneEpoch) {
      _renderObjects = [];
      _renderObjectsEpoch = sceneEpoch;
      for (final o in doc.objects) {
        if (!o.visible) continue;
        final preview = scanPreview;
        final previewing =
            preview != null &&
            preview.objectId == o.id &&
            preview.revision == doc.revision;
        final original = previewing && scanPreviewShowOriginal
            ? (doc.byId(o.scanSourceId ?? -1) ?? o)
            : null;
        final renderMesh =
            original?.mesh ?? (previewing ? preview.result.mesh : o.mesh);
        final mask =
            (!previewing && o.id == selectedObjectId && selection != null)
            ? selection!.faceMask
            : null;
        Float32List? colors;
        if (o.id == selectedObjectId &&
            overlay != AnalysisOverlay.none &&
            overlayColors != null) {
          colors = _expandFaceColors(o.mesh, overlayColors!);
        }
        _renderObjects.add(
          RenderObject(
            renderMesh,
            transform:
                original?.transform ?? (previewing ? identity4() : o.transform),
            color: _materialColor(o),
            faceMask: mask,
            faceColors: colors,
          ),
        );
      }
    }
    final opts = RenderOptions(
      width: frameWidth,
      height: frameHeight,
      wireframe: wireframe,
      showBed: showBed,
      showGrid: showBed,
      bedWidth: printProfile.width,
      bedDepth: printProfile.depth,
      centerBed: false,
      background: const <double>[0.086, 0.094, 0.11],
    );
    final sw = Stopwatch()..start();
    final cameraCopy = camera.clone();
    final rendered = await _sceneRenderer.render(
      _renderObjects,
      cameraCopy,
      opts,
      renderBackendPreference,
      sceneEpoch,
    );
    sw.stop();
    if (_disposed) return;
    final img = await _decode(rendered.rgba, opts.width, opts.height);
    if (_disposed ||
        sceneEpoch != _sceneRenderEpoch ||
        revision != doc.revision) {
      img.dispose();
      return;
    }
    frame?.dispose();
    frame = img;
    lastRenderMs = sw.elapsedMilliseconds;
    renderBackend = rendered.backend;
    renderDiagnostic = rendered.diagnostic;
    hardwareAccelerated = rendered.hardwareAccelerated;
    notify();
  }

  static Future<ui.Image> _decode(Uint8List rgba, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static List<double> _materialColor(SceneObject o) {
    const palette = <List<double>>[
      <double>[0.76, 0.70, 0.60],
      <double>[0.55, 0.66, 0.76],
      <double>[0.72, 0.58, 0.55],
      <double>[0.60, 0.74, 0.62],
    ];
    return palette[o.id % palette.length];
  }

  /// Expands per-vertex analysis values into per-face RGB.
  static Float32List _expandFaceColors(TriMesh mesh, Uint8List perVertex) {
    final out = Float32List(mesh.faceCount * 3);
    for (var f = 0; f < mesh.faceCount; f++) {
      var v = 0;
      for (var k = 0; k < 3; k++) {
        v = mathMax(v, perVertex[mesh.indices[f * 3 + k]]);
      }
      if (v == 255) {
        // Reserved unknown marker for thickness probes; other overlays use 0–254.
        out[f * 3] = .5;
        out[f * 3 + 1] = .5;
        out[f * 3 + 2] = .5;
        continue;
      }
      final t = v / 254.0;
      // Blue (safe) -> yellow -> red (bad)
      final r = (t < 0.5 ? t * 2 : 1.0);
      final g = (t < 0.5 ? 0.6 + t * 0.8 : 1.0 - (t - 0.5) * 1.6);
      final b = (t < 0.5 ? 1.0 - t * 1.6 : 0.2);
      out[f * 3] = r;
      out[f * 3 + 1] = g;
      out[f * 3 + 2] = b;
    }
    return out;
  }

  // ------------------------------------------------------------- selection
  Future<void> pickAndSelect(double sx, double sy) async {
    final obj = selected;
    if (obj == null) return;
    final ray = camera.screenToRay(
      sx,
      sy,
      frameWidth.toDouble(),
      frameHeight.toDouble(),
    );
    final bvh = _spatialCache.bvh(obj, doc.revision);
    final hit = bvh.raycast(ray.origin, ray.direction);
    if (hit == null) {
      status = 'No surface under cursor';
      notify();
      return;
    }
    final world = _spatialCache.worldMesh(obj, doc.revision);
    final sel = Selection.sphereBrush(world, hit.point, brushRadius);
    selection = sel;
    status = 'Selected ${sel.count} faces';
    await render();
  }

  Future<void> selectAll() async {
    final obj = selected;
    if (obj == null) return;
    selection = Selection(
      Uint8List(obj.mesh.faceCount)..fillRange(0, obj.mesh.faceCount, 1),
      obj.mesh.faceCount,
    );
    await render();
  }

  Future<void> expandSelection() async {
    final obj = selected;
    if (obj == null || selection == null) return;
    selection!.expand(obj.mesh);
    await render();
  }

  Future<void> contractSelection() async {
    final obj = selected;
    if (obj == null || selection == null) return;
    selection!.contract(obj.mesh);
    await render();
  }

  Future<void> clearSelection() async {
    selection = null;
    await render();
  }

  // --------------------------------------------------------------- sculpt
  Future<void> sculptAt(double sx, double sy, {bool secondary = false}) =>
      _perform('sculptAt', () => _sculptAtImpl(sx, sy, secondary: secondary));

  Future<void> _sculptAtImpl(
    double sx,
    double sy, {
    bool secondary = false,
  }) async {
    if (_sculptGesture != null && _sculptExpectedRevision != doc.revision) {
      throw const _OperationCancelled(stale: true);
    }
    final obj = selected;
    if (obj == null) return;
    final ray = camera.screenToRay(
      sx,
      sy,
      frameWidth.toDouble(),
      frameHeight.toDouble(),
    );
    final bvh = _spatialCache.bvh(obj, doc.revision);
    final hit = bvh.raycast(ray.origin, ray.direction);
    if (hit == null) return;
    final op = secondary ? BrushOp.smooth : brushOp;
    final center = hit.point;
    final radius = brushRadius;
    final strength = brushStrength;
    final dir = ray.direction;
    final mesh = _spatialCache.worldMesh(obj, doc.revision);
    final pivot = obj.pivot;
    final worldPivot = pivot == null
        ? null
        : Pivot(
            position: objectPivotWorld(obj),
            normal: transformNormal(obj.transform, pivot.normal),
          );
    final result = await _work(
      sculptWorker(mesh, op, center, radius, strength, dir),
    );
    if (_sculptGesture == null || _sculptSnapshotGesture != _sculptGesture) {
      doc.snapshot('Sculpt ${op.name}');
      _sculptSnapshotGesture = _sculptGesture;
    } else {
      doc.revision++;
    }
    obj.mesh = result;
    obj.transform = identity4();
    obj.pivot = worldPivot;
    if (_sculptGesture != null) _sculptExpectedRevision = doc.revision;
    status = 'Sculpted (${result.faceCount} faces)';
    await render();
  }

  // ------------------------------------------------------------ operations
  Future<void> runOp(
    String label,
    Future<TriMesh> Function() fn, {
    bool worldSpace = false,
  }) => _perform(label, () async {
    final obj = selected;
    if (obj == null) return;
    final revision = doc.revision;
    final result = await fn();
    if (revision != doc.revision || doc.byId(obj.id) != obj) {
      throw const _OperationCancelled(stale: true);
    }
    if (_disposed || _cancelled) throw const _OperationCancelled();
    if (result.validate().isNotEmpty) {
      throw FormatException(result.validate().join(', '));
    }
    doc.snapshot(label);
    obj.mesh = result;
    if (worldSpace) {
      // Pivots are stored locally: baking geometry into world coordinates must
      // preserve the user-selected world anchor and its normal.
      final pivot = obj.pivot;
      if (pivot != null) {
        final linear = Float64List.fromList(obj.transform)
          ..[12] = 0
          ..[13] = 0
          ..[14] = 0;
        final normal = <double>[];
        for (var axis = 0; axis < 3; axis++) {
          final inverseColumn = inverseTransformPoint(
            linear,
            List<double>.generate(3, (i) => i == axis ? 1 : 0),
          );
          normal.add(
            List<double>.generate(
              3,
              (i) => inverseColumn[i] * pivot.normal[i],
            ).reduce((a, b) => a + b),
          );
        }
        obj.pivot = Pivot.atPoint(
          transformPoint(obj.transform, pivot.position),
          normal: normal,
        );
      }
      obj.transform = identity4();
    }
    status = '$label done (${result.faceCount} faces)';
  });

  Future<void> doRemesh({
    bool groupAware = false,
    bool selectionOnly = false,
  }) async {
    final obj = selected;
    if (obj == null) return;
    final target = obj.mesh.bounds().diagonal * (0.02 + remeshDensity * 0.06);
    final mesh = obj.mesh;
    final preserveGroups = groupAware && mesh.faceGroups != null;
    final mask = selectionOnly ? selection?.faceMask : null;
    if (selectionOnly && (mask == null || !mask.any((v) => v != 0))) {
      status = 'Select faces before remeshing';
      notify();
      return;
    }
    await runOp('Remesh', () async {
      final result = await _work(
        remeshWorker(mesh, target, preserveGroups, mask: mask),
      );
      operationWarning = result.fallbackReason;
      return result.mesh;
    });
  }

  Future<void> doReduce({bool selectionOnly = false}) async {
    final obj = selected;
    if (obj == null) return;
    final pct = reducePercent;
    final mesh = obj.mesh;
    final mask = selectionOnly ? selection?.faceMask : null;
    if (selectionOnly && (mask == null || !mask.any((v) => v != 0))) {
      status = 'Select faces before reducing';
      notify();
      return;
    }
    await runOp('Reduce', () => _work(reduceWorker(mesh, pct, mask: mask)));
  }

  Future<void> extractSelection() =>
      _perform('extractSelection', () => _extractSelectionImpl());

  Future<void> _extractSelectionImpl() async {
    final obj = selected;
    final sel = selection;
    if (obj == null || sel == null) return;
    final faces = <int>{
      for (var f = 0; f < obj.mesh.faceCount; f++)
        if (sel.faceMask[f] != 0) f,
    };
    if (faces.isEmpty) return;
    final out = ComplexTools.extract(obj.worldMesh(), faces);
    if (out.faceCount == 0) return;
    await _addObjectImpl(out, 'Extracted region');
    status = 'Extracted ${out.faceCount} faces';
  }

  Future<void> makePart() => _perform('makePart', () => _makePartImpl());

  Future<void> _makePartImpl() async {
    final obj = selected;
    final sel = selection;
    if (obj == null || sel == null) return;
    final faces = <int>{
      for (var f = 0; f < obj.mesh.faceCount; f++)
        if (sel.faceMask[f] != 0) f,
    };
    if (faces.isEmpty) return;
    final mesh = obj.worldMesh();
    final out = await _work(makePartWorker(mesh, faces));
    await _addObjectImpl(out, 'Solid part');
    status = 'Made solid part (${out.faceCount} faces)';
  }

  Future<void> doCreatePivot() =>
      _perform('doCreatePivot', () => _doCreatePivotImpl());

  Future<void> _doCreatePivotImpl() async {
    final obj = selected;
    if (obj == null) return;
    if (obj.mesh.vertexCount == 0) return;
    var vertex = 0;
    final sel = selection;
    if (sel != null) {
      for (var f = 0; f < obj.mesh.faceCount; f++) {
        if (sel.faceMask[f] != 0) {
          vertex = obj.mesh.indices[f * 3];
          break;
        }
      }
    }
    doc.snapshot('Pivot');
    obj.pivot = Pivot.atVertex(obj.mesh, vertex);
    status = 'Pivot created';
    notify();
  }

  Future<void> doMakeSolid() async {
    final obj = selected;
    if (obj == null) return;
    final minimum = solidMinThickness;
    final mesh = obj.worldMesh();
    final res = solidResolution.toInt();
    final mode = solidMode;
    final offset = solidOffset;
    final smooth = solidSmoothing;
    await runOp('Make Solid', () async {
      final result = await _work(
        makeSolidWorker(mesh, mode, res, offset, smooth, minimum),
      );
      _reportWallVerification(result);
      return result.mesh;
    }, worldSpace: true);
  }

  Future<void> doHollow() async {
    final obj = selected;
    if (obj == null) return;
    final minimum = hollowMinThickness;
    final mesh = obj.worldMesh();
    final t = hollowThickness;
    final holes = hollowHoles;
    final res = solidResolution.toInt();
    await runOp('Hollow', () async {
      final result = await _work(hollowWorker(mesh, t, holes, res, minimum));
      _reportWallVerification(result);
      return result.mesh;
    }, worldSpace: true);
  }

  void _reportWallVerification(SolidResult result) {
    final certificate = result.wallCertificate;
    if (certificate == null) return;
    final change = result.appliedShellThickness == null
        ? 'offset ${result.appliedOffset.toStringAsFixed(3)} mm'
        : 'shell ${result.appliedShellThickness!.toStringAsFixed(3)} mm';
    operationWarning =
        'Verified inward-normal clearance '
        '${certificate.requestedThickness.toStringAsFixed(3)} mm; $change; '
        '${result.thicknessAttempts} attempt(s)'
        '${result.reconstructionDiagnostic == null ? '' : '; ${result.reconstructionDiagnostic}'}';
  }

  Future<void> doPlaneCut() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final b = mesh.bounds();
    final mins = [b.minX, b.minY, b.minZ], maxs = [b.maxX, b.maxY, b.maxZ];
    final y = (mins[planeAxis] + maxs[planeAxis]) / 2 + planeOffset;
    final fill = planeFill;
    await runOp(
      'Plane Cut',
      () => _work(planeCutWorker(mesh, y, fill, planeAxis, planeKeepPositive)),
    );
  }

  Future<void> doMirror() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final offset = mirrorPlaneOffset;
    final keep = mirrorKeepOriginal;
    final weld = mirrorWeld;
    final diag = mesh.bounds().diagonal;
    await runOp(
      'Mirror',
      () => _work(mirrorWorker(mesh, offset, keep, weld, diag)),
    );
  }

  Future<void> doExtrude() async {
    final obj = selected;
    if (obj == null) return;
    final sel = selection;
    if (sel == null || sel.count == 0) {
      status = 'Extrude needs a face selection';
      notify();
      return;
    }
    final mesh = obj.mesh;
    final mask = sel.faceMask;
    final distance = extrudeDistance;
    final smooth = extrudeSmooth;
    await runOp(
      'Extrude',
      () => _work(extrudeWorker(mesh, mask, distance, smooth)),
    );
  }

  Future<void> doSeparateShells() =>
      _perform('doSeparateShells', () => _doSeparateShellsImpl());

  Future<void> _doSeparateShellsImpl() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final shells = await _work(separateWorker(mesh));
    if (shells.length <= 1) {
      status = 'Single shell, nothing to separate';
      notify();
      return;
    }
    doc.snapshot('Separate shells');
    obj.mesh = shells.first;
    for (var i = 1; i < shells.length; i++) {
      doc.add(shells[i], name: '${obj.name} shell ${i + 1}').transform =
          Float64List.fromList(obj.transform);
    }
    status = 'Separated into ${shells.length} shells';
    selection = null;
    await render();
  }

  // ------------------------------------------------------- remaining edits
  Future<void> doStamp() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final mask = selection?.faceMask;
    final pattern = stampPattern;
    final radius = stampRadius;
    final height = stampHeight;
    await runOp(
      'Stamp',
      () => _work(stampWorker(mesh, mask, radius, height, pattern)),
    );
  }

  Future<void> doFlipNormals() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final mask = selection?.faceMask;
    await runOp('Flip normals', () => _work(flipWorker(mesh, mask)));
  }

  Future<void> doSmoothMesh() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    await runOp('Smooth', () => _work(smoothWorker(mesh)));
  }

  Future<void> doDropToBed() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.worldMesh();
    await runOp('Drop to bed', () => _work(dropWorker(mesh)), worldSpace: true);
  }

  Future<void> doCenterOnBed() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.worldMesh();
    await runOp(
      'Center on bed',
      () => _work(centerWorker(mesh)),
      worldSpace: true,
    );
  }

  Future<void> doDuplicate() =>
      _perform('doDuplicate', () => _doDuplicateImpl());

  Future<void> _doDuplicateImpl() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.worldMesh();
    final offset = mesh.bounds().extentX + 2;
    final copy = await _work(duplicateWorker(mesh, offset));
    doc.snapshot('Duplicate');
    final added = doc.add(copy, name: '${obj.name} copy');
    selectedObjectId = added.id;
    selection = null;
    status = 'Duplicated ${obj.name}';
    await render();
  }

  Future<void> doCombineAll() =>
      _perform('doCombineAll', () => _doCombineAllImpl());

  Future<void> _doCombineAllImpl() async {
    final obj = selected;
    if (obj == null || doc.objects.length < 2) {
      status = 'Combine needs at least two objects';
      notify();
      return;
    }
    final combinable = doc.objects
        .where((o) => o.visible && !o.locked)
        .toList();
    if (combinable.length < 2) {
      throw StateError("Combine needs two visible editable objects");
    }
    if (!combinable.contains(obj)) {
      throw StateError('Select a visible editable object before combining');
    }
    final sources = combinable.map((o) => o.worldMesh()).toList();
    final combined = await _work(combineWorker(sources));
    doc.snapshot('Combine');
    obj.mesh = combined;
    obj.transform = identity4();
    for (final other in combinable) {
      if (other.id != obj.id) doc.remove(other.id);
    }
    selection = null;
    refreshShellCount();
    status = 'Combined ${sources.length} objects into ${obj.name}';
    await render();
  }

  Future<void> doMakePattern() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final cx = patternCountX;
    final cz = patternCountZ;
    final gap = patternGap;
    await runOp('Pattern', () => _work(patternWorker(mesh, cx, cz, gap)));
  }

  Future<void> doFitPrimitive() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    final kind = primitiveKind;
    await runOp('Fit primitive', () => _work(primitiveWorker(mesh, kind)));
  }

  Future<void> doGenerateFaceGroups() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    await runOp('Generate face groups', () => _work(groupsWorker(mesh)));
  }

  Future<void> doMeasure() => _perform('doMeasure', () => _doMeasureImpl());

  Future<void> _doMeasureImpl() async {
    final obj = selected;
    if (obj == null) return;
    notify();
    final mesh = obj.worldMesh();
    final r = await _work(measureWorker(mesh));
    final d = r.dimensions.map((v) => v.toStringAsFixed(2)).join(' x ');
    status =
        'Measure: $d | area ${r.surfaceArea.toStringAsFixed(1)} | '
        'volume ${r.volume.toStringAsFixed(1)} | ${r.shellCount} shell(s) | '
        '${r.watertight ? "watertight" : "${r.boundaryEdgeCount} boundary edges"}';
    notify();
  }

  Future<void> doClearance() =>
      _perform('doClearance', () => _doClearanceImpl());

  Future<void> _doClearanceImpl() async {
    final obj = selected;
    if (obj == null) return;
    SceneObject? other;
    for (final o in doc.objects) {
      if (o.id != obj.id) {
        other = o;
        break;
      }
    }
    if (other == null) {
      status = 'Clearance needs a second object';
      notify();
      return;
    }
    notify();
    final a = obj.worldMesh();
    final b = other.worldMesh();
    final gap = await _work(clearanceWorker(a, b));
    status = gap.isFinite
        ? 'Clearance ${obj.name} / ${other.name}: ${gap.toStringAsFixed(2)}'
        : 'Clearance: no surface found';
    notify();
  }

  Future<void> doStitchCracks() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.mesh;
    await runOp('Stitch cracks', () => _work(stitchWorker(mesh)));
  }

  Future<void> doAlignToTarget() =>
      _perform('doAlignToTarget', () => _doAlignToTargetImpl());

  Future<void> _doAlignToTargetImpl() async {
    final obj = selected;
    if (obj == null) return;
    SceneObject? target;
    for (final o in doc.objects) {
      if (o.id != obj.id) {
        target = o;
        break;
      }
    }
    if (target == null) {
      status = 'Align needs a second object';
      notify();
      return;
    }
    notify();
    final source = obj.worldMesh();
    final targetMesh = target.worldMesh();
    final t = await _work(alignWorker(source, targetMesh));
    final aligned = obj.worldMesh();
    aligned.transform(t);
    doc.snapshot('Align to target');
    obj.mesh = aligned;
    obj.transform = identity4();
    final rms = await _work(rmsWorker(obj.mesh, targetMesh));
    selection = null;
    status =
        'Aligned ${obj.name} to ${target.name} '
        '(RMS ${rms.toStringAsFixed(2)} mm)';
    await render();
  }

  Future<void> doSupports() => _perform('doSupports', () => _doSupportsImpl());

  Future<void> _doSupportsImpl() async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.worldMesh();
    final angle = supportAngle;
    final density = supportDensity;
    final result = await _work(supportsWorker(mesh, angle, density));
    if (result.supports.faceCount == 0) {
      status = 'No overhangs above ${angle.toStringAsFixed(0)}°';
      notify();
      return;
    }
    doc.snapshot('Supports');
    final supportObj = doc.add(result.supports, name: 'Supports');
    supportObj.transform = identity4();
    status = 'Supports: ${result.postCount} posts, ${result.strutCount} struts';
    await render();
  }

  Future<void> doAnalysis(AnalysisOverlay mode) =>
      _perform('doAnalysis', () => _doAnalysisImpl(mode));

  Future<void> _doAnalysisImpl(AnalysisOverlay mode) async {
    final obj = selected;
    if (obj == null) return;
    status = 'Analysing...';
    notify();
    final mesh = obj.worldMesh();
    Uint8List colors;
    String summary;
    switch (mode) {
      case AnalysisOverlay.thickness:
        final th = thicknessThreshold;
        final r = await _work(thicknessWorker(mesh, th));
        colors = Uint8List.fromList([
          for (final value in r.perVertex)
            !value.isFinite
                ? 255
                : (254 * (1 - value / (th * 2)).clamp(0.0, 1.0)).round(),
        ]);
        summary =
            'min ${r.minThickness.toStringAsFixed(2)}, '
            'mean ${r.meanThickness.toStringAsFixed(2)}, '
            '${r.belowThresholdCount} verts below $th; ${r.unknownCount} unknown probes';
      case AnalysisOverlay.overhang:
        final angle = overhangAngle;
        final r = await _work(overhangWorker(mesh, angle));
        colors = _normalizeToBytes(r.perVertexSeverity, 1.0);
        summary =
            '${r.faceCount} overhang faces, '
            '${(100 * r.overhangArea / (r.totalArea == 0 ? 1 : r.totalArea)).toStringAsFixed(1)}% of area';
      case AnalysisOverlay.stability:
        final r = await _work(stabilityWorker(mesh));
        colors = Uint8List(mesh.vertexCount);
        summary =
            'COM (${r.centerOfMass.map((v) => v.toStringAsFixed(1)).join(', ')}) '
            '${r.centerInsideSupport ? "inside" : "OUTSIDE"} base, '
            'tip ${r.minTipAngleDegrees.toStringAsFixed(1)}°';
      case AnalysisOverlay.deviation:
        final reference =
            doc.objects
                .where((o) => o.id != obj.id && o.isTarget)
                .firstOrNull ??
            doc.objects.where((o) => o.id != obj.id).firstOrNull;
        if (reference == null) {
          throw const FormatException('Deviation needs a reference object');
        }
        final referenceMesh = reference.worldMesh();
        final result = await _work(deviationWorker(mesh, referenceMesh));
        colors = _normalizeToBytes(
          result.perVertexDistance,
          result.maxDistance,
        );
        summary =
            'Deviation from ${reference.name}: max ${result.maxDistance.toStringAsFixed(3)} mm';
      case AnalysisOverlay.none:
        colors = Uint8List(mesh.vertexCount);
        summary = 'No overlay';
    }
    overlayColors = colors;
    overlay = mode;
    status = summary;
    await render();
  }

  static Uint8List _normalizeToBytes(Float32List values, double maxValue) {
    final out = Uint8List(values.length);
    final m = maxValue <= 0 ? 1.0 : maxValue;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (!v.isFinite) {
        out[i] = 0;
        continue;
      }
      out[i] = (254 * (v / m).clamp(0.0, 1.0)).round();
    }
    return out;
  }

  // ------------------------------------------------------------ inspection
  Future<void> inspectMesh() =>
      _perform('inspectMesh', () => _inspectMeshImpl());

  Future<void> _inspectMeshImpl() async {
    final obj = selected;
    if (obj == null) return;
    scanReport = await _work(
      scanInspectWorker(obj.worldMesh(), printProfile, scanFragmentArea),
    );
    scanReportRevision = doc.revision;
    scanReportObjectId = obj.id;
    tool = StudioTool.scan;
    status =
        'Scan inspection: ${scanReport!.findings.length} findings; review the report';
  }

  Future<void> autoRepair() => previewScan(ScanStep('repair'));

  // ----------------------------------------------------------------- scene
  Future<void> addObject(TriMesh mesh, String name) =>
      _perform('addObject', () => _addObjectImpl(mesh, name));

  Future<void> _addObjectImpl(TriMesh mesh, String name) async {
    doc.snapshot('Add $name');
    final obj = doc.add(mesh, name: name);
    selectedObjectId = obj.id;
    _frameObject(obj);
    status = 'Added $name';
    await render();
  }

  Future<void> importPath(String path, {double unitScale = 1}) =>
      _perform('importPath', () => _importPathImpl(path, unitScale));

  Future<void> _importPathImpl(String path, double unitScale) async {
    if (!unitScale.isFinite || unitScale <= 0) {
      throw const FormatException('Invalid import units');
    }
    final f = File(path);
    if (!f.existsSync()) {
      status = 'Missing: $path';
      notify();
      return;
    }
    if (await f.length() > MeshIO.maxFileBytes) {
      throw const FormatException('File exceeds 256 MiB');
    }
    // OBJ reads its bounded companion graph inside the worker; avoid loading
    // another full copy of the main text on the UI isolate.
    final bytes = path.toLowerCase().endsWith('.obj')
        ? Uint8List(0)
        : await f.readAsBytes();
    if (path.toLowerCase().endsWith('.mix')) {
      final objects = await _work(readMixWorker(bytes));
      for (final o in objects) {
        if (o.mesh.validate().isNotEmpty) {
          throw const FormatException('Invalid mesh');
        }
      }
      if (objects.isEmpty) {
        status = 'No mesh found in $path';
        notify();
        return;
      }
      if (sourceAttachments.fold<int>(
            bytes.length,
            (n, source) => n + source.bytes.length,
          ) >
          MeshIO.maxFileBytes) {
        throw const FormatException(
          'Original source attachments exceed 256 MiB',
        );
      }
      doc.snapshot('Import $path');
      SceneObject? first;
      for (final o in objects) {
        final obj = doc.add(o.mesh, name: o.name);
        first ??= obj;
      }
      sourceAttachments.add(
        ProjectSourceAttachment(
          name: path.split(RegExp(r'[/\\]')).last,
          bytes: bytes,
        ),
      );
      selectedObjectId = first!.id;
      selection = null;
      _frameObject(first);
      status =
          'Imported ${objects.length} object(s) from ${path.split(RegExp(r'[/\\]')).last}';
      await render();
      return;
    }
    final mesh = await _work(readMeshWorker(path, bytes));
    if (!path.toLowerCase().endsWith('.3mf') && unitScale != 1) {
      mesh.transform(scale4(unitScale));
    }
    if (mesh.validate().isNotEmpty) {
      throw const FormatException('Import unit conversion overflow');
    }
    await _addObjectImpl(mesh, path.split(RegExp(r'[/\\]')).last);
  }

  Future<void> exportSelected(String path) =>
      _perform('exportSelected', () => _exportSelectedImpl(path));

  Future<void> _exportSelectedImpl(String path) async {
    final obj = selected;
    if (obj == null) return;
    final mesh = obj.worldMesh();
    final prepared = await _work(prepareMeshExportWorker(path, mesh));
    // Cancellation and revision checks finish before committing files. The
    // asynchronous commit writes only already encoded bytes and is atomic.
    final companions = await MeshIO.commitExport(path, prepared);
    status = companions == null
        ? 'Exported $path'
        : 'Exported $path; keep companion folder $companions with the OBJ';
    notify();
  }

  Future<void> undo() async {
    if (interactionLocked || _disposed) return;
    if (doc.undo()) {
      dirty = true;
      _invalidateGeometry();
      status = 'Undo';
      await render();
    }
  }

  Future<void> redo() async {
    if (interactionLocked || _disposed) return;
    if (doc.redo()) {
      dirty = true;
      _invalidateGeometry();
      status = 'Redo';
      await render();
    }
  }

  /// Counts shells on demand; building topology on every panel rebuild would
  /// be wasteful for large meshes.
  void refreshShellCount() {
    final object = selected;
    shellCount = object == null
        ? 0
        : _spatialCache.topology(object, doc.revision).components().$2;
  }

  void notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sceneRenderer.dispose();
    unawaited(cancelInteraction());
    final work = _activeWork;
    if (work != null) cancelWorker(work);
    frame?.dispose();
    super.dispose();
  }

  void setTool(StudioTool t) {
    if (scanPreview != null) {
      status = 'Apply or cancel the scan preview first';
      notify();
      return;
    }
    if (interactionLocked) return;
    tool = t;
    if (t == StudioTool.separate) refreshShellCount();
    status = 'Tool: ${t.name}';
    notify();
  }

  void toggleWireframe() {
    wireframe = !wireframe;
    _scheduleRender();
  }

  void toggleBed() {
    showBed = !showBed;
    _scheduleRender();
  }

  void setFrameSize(int w, int h) {
    w = w.clamp(1, 4096);
    h = h.clamp(1, 4096);
    if (w == frameWidth && h == frameHeight) return;
    frameWidth = w;
    frameHeight = h;
    _scheduleRender();
  }
}

int mathMax(int a, int b) => a > b ? a : b;

class _OperationCancelled implements Exception {
  final bool stale;
  const _OperationCancelled({this.stale = false});
}
