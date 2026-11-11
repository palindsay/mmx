part of 'studio_state.dart';

class ScanPreview {
  final int objectId, revision;
  final ScanStep step;
  final ScanEditResult result;
  final SurfaceDeviation fromOriginal;
  final bool usesSelection;
  ScanPreview(
    this.objectId,
    this.revision,
    this.step,
    this.result,
    this.fromOriginal,
    this.usesSelection,
  );
}

extension ScanTools on StudioState {
  bool get scanReportCurrent =>
      scanReport != null &&
      scanReportRevision == doc.revision &&
      scanReportObjectId == selectedObjectId;

  Future<void> inspectScan() => _perform('Scan inspection', () async {
    final obj = selected;
    if (obj == null) return;
    final profile = printProfile;
    final area = scanFragmentArea;
    final report = await _work(
      scanInspectWorker(obj.worldMesh(), profile, area),
    );
    scanReport = report;
    scanReportRevision = doc.revision;
    scanReportObjectId = obj.id;
    status =
        'Scan preflight: ${report.findings.where((f) => f.severity == ScanSeverity.error).length} errors, '
        '${report.findings.where((f) => f.severity == ScanSeverity.warning).length} warnings; review unknown checks';
  });

  void selectScanFinding(ScanFinding finding) {
    final obj = selected;
    if (obj == null ||
        !scanReportCurrent ||
        interactionLocked ||
        scanPreview != null) {
      return;
    }
    final mask = Uint8List(obj.mesh.faceCount);
    for (final f in finding.faces) {
      if (f >= 0 && f < mask.length) mask[f] = 1;
    }
    if (finding.vertices.isNotEmpty) {
      final vertices = finding.vertices.toSet();
      for (var f = 0; f < mask.length; f++) {
        if (vertices.contains(obj.mesh.indices[f * 3]) ||
            vertices.contains(obj.mesh.indices[f * 3 + 1]) ||
            vertices.contains(obj.mesh.indices[f * 3 + 2])) {
          mask[f] = 1;
        }
      }
    }
    selection = Selection(mask, mask.where((v) => v != 0).length);
    notify();
    _scheduleRender();
  }

  Future<void> previewScan(ScanStep step) => _perform('Scan preview', () async {
    final obj = selected;
    if (obj == null) return;
    final revision = doc.revision;
    final input = obj.worldMesh();
    final original = doc.byId(obj.scanSourceId ?? -1)?.worldMesh() ?? input;
    final mask = selection?.faceMask;
    final result = await _work(scanEditWorker(input, step, mask));
    final deviation = await _work(scanDeviationWorker(original, result.mesh));
    if (doc.revision != revision) throw const _OperationCancelled(stale: true);
    scanPreview = ScanPreview(
      obj.id,
      revision,
      step,
      result,
      deviation,
      mask != null &&
          {'fragments', 'denoise', 'reduce', 'remesh'}.contains(step.operation),
    );
    scanPreviewShowOriginal = false;
    tool = StudioTool.scan;
    manipulatorMode = ManipulatorMode.none;
    overlay = AnalysisOverlay.none;
    overlayColors = null;
    _sceneRenderEpoch++;
    status =
        'Preview ${step.operation}: ${result.mesh.faceCount} faces. Apply or Cancel.';
  });

  Future<void> cancelScanPreview() async {
    if (busy || scanPreview == null) return;
    scanPreview = null;
    _sceneRenderEpoch++;
    status = 'Preview canceled; project unchanged';
    notify();
    await render();
  }

  void showScanOriginal(bool value) {
    if (scanPreview == null || busy) return;
    scanPreviewShowOriginal = value;
    _scheduleRender();
    notify();
  }

  Future<void> applyScanPreview() async {
    final preview = scanPreview;
    if (preview == null || busy) return;
    final applied = await _perform('Apply scan preview', () async {
      final obj = selected;
      if (obj == null ||
          obj.id != preview.objectId ||
          doc.revision != preview.revision) {
        throw StateError('Preview is stale; cancel and preview again');
      }
      // Prepare the complete candidate scene, including its original, before
      // committing. Serialization preflight prevents unsaveable scan projects.
      final candidate = doc.objects.map((o) => o.clone()).toList();
      final changed = candidate.firstWhere((o) => o.id == obj.id);
      SceneObject? original;
      if (doc.byId(obj.scanSourceId ?? -1) == null) {
        final id = candidate.fold<int>(0, (m, o) => o.id > m ? o.id : m) + 1;
        original = SceneObject(id, 'Original: ${obj.name}', obj.worldMesh())
          ..locked = true
          ..visible = false
          ..isTarget = true;
        candidate.add(original);
        changed.scanSourceId = id;
      }
      changed.mesh = preview.result.mesh;
      changed.transform = identity4();
      changed.pivot = null;
      final inputHash = await _work(fingerprintWorker(obj.worldMesh()));
      final outputHash = await _work(fingerprintWorker(preview.result.mesh));
      changed.scanHistory.add(
        jsonEncode({
          'step': preview.step.toJson(),
          'deviation': preview.fromOriginal.toJson(),
          'inferredGroup': preview.result.inferredGroup,
          'usesSelection': preview.usesSelection,
          'inputMeshSha256': inputHash,
          'outputMeshSha256': outputHash,
        }),
      );
      await _work(
        encodeProjectWorker(
          ProjectData(
            candidate,
            camera: camera,
            selectedId: obj.id,
            sourceAttachments: sourceAttachments,
            printProfile: printProfile,
          ),
        ),
      );
      doc.snapshot('Scan ${preview.step.operation}');
      if (original != null) {
        final saved = doc.add(original.mesh, name: original.name)
          ..locked = true
          ..visible = false
          ..isTarget = true;
        obj.scanSourceId = saved.id;
      }
      obj.mesh = preview.result.mesh;
      obj.transform = identity4();
      obj.pivot = null;
      obj.scanHistory = changed.scanHistory;
      scanPreview = null;
      status =
          'Applied ${preview.step.operation}; original preserved. ${preview.result.note}';
    });
    if (applied) await inspectScan();
  }

  Future<void> compareScanOriginal() => _perform('Compare scan', () async {
    final obj = selected;
    final original = doc.byId(obj?.scanSourceId ?? -1);
    if (obj == null || original == null) {
      throw StateError('Apply a scan edit to retain an original first');
    }
    final measurement = await _work(
      scanDeviationWorker(original.worldMesh(), obj.worldMesh()),
    );
    status =
        'Original comparison: sampled max ${measurement.maximum.toStringAsFixed(3)} mm, '
        'RMS ${measurement.rms.toStringAsFixed(3)} mm; ${measurement.samples} bidirectional samples';
  });

  Future<bool> exportScanData(String path, {bool recipe = false}) => _perform(
    'Export scan data',
    () async {
      final obj = selected;
      if (obj == null) throw StateError('Select a scan first');
      final history = [
        for (final entry in obj.scanHistory)
          jsonDecode(entry) as Map<String, dynamic>,
      ];
      final Map<String, Object?> data;
      if (recipe) {
        if (history.any((entry) => entry['usesSelection'] != false)) {
          throw StateError(
            'This history contains regional edits or older steps. Export a report to retain their provenance; reusable recipes require whole-mesh steps.',
          );
        }
        final original = doc.byId(obj.scanSourceId ?? -1);
        if (history.isEmpty ||
            original == null ||
            history.first['inputMeshSha256'] !=
                await _work(fingerprintWorker(original.worldMesh())) ||
            history.last['outputMeshSha256'] !=
                await _work(fingerprintWorker(obj.worldMesh())) ||
            List.generate(
              history.length - 1,
              (i) =>
                  history[i]['outputMeshSha256'] ==
                  history[i + 1]['inputMeshSha256'],
            ).contains(false)) {
          throw StateError(
            'Other edits or placement changes interrupt this cleanup recipe. Export the preflight report for the complete stored history.',
          );
        }
        data = ScanRecipe([
          for (final entry in history)
            ScanStep.fromJson(entry['step'] as Map<String, dynamic>),
        ]).toJson();
      } else {
        final mesh = obj.worldMesh();
        final report = await _work(
          scanInspectWorker(mesh, printProfile, scanFragmentArea),
        );
        final original = doc.byId(obj.scanSourceId ?? -1);
        data = {
          'version': 1,
          'object': obj.name,
          'consumedMeshSha256': await _work(fingerprintWorker(mesh)),
          'originalMeshSha256': original == null
              ? null
              : await _work(fingerprintWorker(original.worldMesh())),
          'history': history,
          'preflight': report.toJson(),
        };
      }
      await writeFileAtomically(
        path,
        Uint8List.fromList(
          utf8.encode('${const JsonEncoder.withIndent('  ').convert(data)}\n'),
        ),
      );
      status = 'Exported scan ${recipe ? 'recipe' : 'report'} to $path';
    },
  );

  Future<void> doSliceReport() => _perform('Slice report', () async {
    final obj = selected;
    if (obj == null) return;
    final result = await _work(sliceWorker(obj.worldMesh(), printLayerHeight));
    final open = result.layers.fold<int>(
      0,
      (n, l) => n + l.loops.where((loop) => !loop.closed).length,
    );
    status =
        'Cross sections: ${result.layers.length} layers at $printLayerHeight mm, $open open contours';
  });

  Future<void> discardSelection() async {
    final obj = selected, mask = selection?.faceMask;
    if (obj == null || mask == null) return;
    await runOp(
      'Discard selection',
      () => _work(discardWorker(obj.mesh, mask)),
    );
  }

  Future<void> smoothSelection() async {
    final obj = selected, mask = selection?.faceMask;
    if (obj == null || mask == null) return;
    await runOp(
      'Smooth selection',
      () => _work(denoiseWorker(obj.mesh, mask, scanDisplacement)),
    );
  }

  Future<void> sceneAction(int id, String action, {String? name}) =>
      _perform('Scene metadata', () async {
        final obj = doc.byId(id);
        if (obj == null) return;
        if (action == 'delete' &&
            (obj.locked || doc.objects.any((o) => o.scanSourceId == id))) {
          throw StateError(
            'Retained originals cannot be deleted; start a new project to discard the scan',
          );
        }
        if (action == 'rename' &&
            (name == null || name.trim().isEmpty || name.length > 256)) {
          throw ArgumentError('Enter a name of 1–256 characters');
        }
        doc.snapshot(action);
        switch (action) {
          case 'delete':
            doc.remove(id);
          case 'rename':
            obj.name = name!.trim();
          case 'visibility':
            obj.visible = !obj.visible;
          case 'target':
            obj.isTarget = !obj.isTarget;
          case 'isolate':
            for (final other in doc.objects) {
              other.visible = other.id == id;
            }
          case 'showAll':
            for (final other in doc.objects) {
              other.visible = !other.locked;
            }
          default:
            throw ArgumentError('Unknown scene action');
        }
        status = '${obj.name}: $action';
      });
}
