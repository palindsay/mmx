import 'dart:io';

import 'worker_runtime.dart';

import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';

import '../render/desktop_renderer.dart';

// Top-level dispatch keeps UI images, listeners and pending futures out of isolates.
Future<Uint8List> encodeProjectWorker(ProjectData project) =>
    executeWorker(() => ProjectIO.write(project));

Future<ProjectData> decodeProjectWorker(String path) => executeWorker(() {
  final file = File(path);
  if (file.lengthSync() > MeshIO.maxFileBytes) {
    throw const FormatException('Project exceeds size limit');
  }
  return ProjectIO.read(file.readAsBytesSync());
});

Future<BooleanResult> booleanWorker(
  TriMesh a,
  TriMesh b,
  BooleanOp op,
  bool precise,
  int resolution,
) => executeWorker(
  () => precise
      ? PreciseBoolean.computeDetailed(a, b, op, resolution: resolution)
      : BooleanResult(
          Solidifier.boolean(a, b, op, resolution: resolution).mesh,
        ),
);

Future<PackResult> packWorker(
  List<TriMesh> meshes, {
  PrintProfile profile = const PrintProfile(),
}) => executeWorker(
  () => Packer.pack(
    meshes,
    bedWidth: profile.width,
    bedDepth: profile.depth,
    border: profile.border,
    quality: 1,
  ),
);

Future<TriMesh> sculptWorker(
  TriMesh mesh,
  BrushOp op,
  List<double> center,
  double radius,
  double strength,
  List<double> dir,
) => executeWorker(
  () => Sculptor.apply(
    mesh,
    op: op,
    center: center,
    radius: radius,
    strength: strength,
    direction: <double>[-dir[0], -dir[1], -dir[2]],
    refine: true,
  ),
);

Future<RemeshResult> remeshWorker(
  TriMesh mesh,
  double target,
  bool preserveGroups, {
  Uint8List? mask,
}) => executeWorker(
  () => mask == null
      ? IsotropicRemesher.remeshDetailed(
          mesh,
          targetEdgeLength: target,
          iterations: 5,
          preserveGroupBoundaries: preserveGroups,
        )
      : RemeshResult(
          editSelection(
            mesh,
            mask,
            (patch) => IsotropicRemesher.remesh(
              patch,
              targetEdgeLength: target,
              iterations: 5,
              preserveGroupBoundaries: preserveGroups,
            ),
          ),
        ),
);

Future<TriMesh> reduceWorker(TriMesh mesh, double pct, {Uint8List? mask}) =>
    executeWorker(
      () => mask == null
          ? Decimator.reduce(mesh, percentage: pct)
          : editSelection(
              mesh,
              mask,
              (patch) => Decimator.reduce(patch, percentage: pct),
            ),
    );

Future<TriMesh> makePartWorker(TriMesh mesh, Set<int> faces) => executeWorker(
  () => ComplexTools.makeSolidPart(mesh, faces, resolution: 64),
);

Future<SolidResult> makeSolidWorker(
  TriMesh mesh,
  SolidMode mode,
  int res,
  double offset,
  int smooth,
  double minimumThickness,
) => executeWorker(
  () => Solidifier.makeSolid(
    mesh,
    mode: mode,
    resolution: res,
    offset: offset,
    smoothing: smooth,
    minThickness: minimumThickness,
  ),
);

Future<SolidResult> hollowWorker(
  TriMesh mesh,
  double t,
  int holes,
  int res,
  double minimumThickness,
) => executeWorker(
  () => Solidifier.hollow(
    mesh,
    thickness: t,
    holes: holes,
    holeRadius: t * 1.2,
    resolution: res,
    minThickness: minimumThickness,
  ),
);

Future<TriMesh> planeCutWorker(
  TriMesh mesh,
  double y,
  bool fill,
  int axis,
  bool keepPositive,
) => executeWorker(
  () => PlaneCut.cut(
    mesh,
    point: List<double>.generate(3, (i) => i == axis ? y : 0),
    normal: List<double>.generate(3, (i) => i == axis ? 1 : 0),
    keepPositive: keepPositive,
    fill: fill,
  ),
);

Future<TriMesh> mirrorWorker(
  TriMesh mesh,
  double offset,
  bool keep,
  bool weld,
  double diag,
) => executeWorker(
  () => Mirror.mirror(
    mesh,
    point: <double>[offset, 0, 0],
    normal: <double>[1, 0, 0],
    keepOriginal: keep,
    weldTolerance: weld ? diag * 1e-4 : 0,
  ),
);

Future<TriMesh> extrudeWorker(
  TriMesh mesh,
  Uint8List mask,
  double distance,
  bool smooth,
) => executeWorker(
  () => Extruder.extrude(
    mesh,
    faceMask: mask,
    distance: distance,
    smoothBoundary: smooth,
  ),
);

Future<List<TriMesh>> separateWorker(TriMesh mesh) =>
    executeWorker(() => ShellSeparator.separate(mesh));

Future<TriMesh> stampWorker(
  TriMesh mesh,
  Uint8List? mask,
  double radius,
  double height,
  StampPattern pattern,
) => executeWorker(() {
  var cx = 0.0, cy = 0.0, cz = 0.0;
  var n = 0;
  if (mask != null) {
    for (var f = 0; f < mesh.faceCount; f++) {
      if (f >= mask.length || mask[f] == 0) continue;
      for (var k = 0; k < 3; k++) {
        final v = mesh.indices[f * 3 + k];
        cx += mesh.vx(v);
        cy += mesh.vy(v);
        cz += mesh.vz(v);
        n++;
      }
    }
  }
  if (n == 0) {
    var best = 0;
    for (var v = 1; v < mesh.vertexCount; v++) {
      if (mesh.vy(v) > mesh.vy(best)) best = v;
    }
    cx = mesh.vx(best);
    cy = mesh.vy(best);
    cz = mesh.vz(best);
    n = 1;
  }
  return StampTool.apply(
    mesh,
    center: <double>[cx / n, cy / n, cz / n],
    radius: radius,
    height: height,
    pattern: pattern,
  );
});

Future<TriMesh> flipWorker(TriMesh mesh, Uint8List? mask) =>
    executeWorker(() => Modify.flipNormals(mesh, faceMask: mask));

Future<TriMesh> smoothWorker(TriMesh mesh) =>
    executeWorker(() => Modify.smooth(mesh, iterations: 8));

Future<TriMesh> dropWorker(TriMesh mesh) =>
    executeWorker(() => Modify.dropToBed(mesh));

Future<TriMesh> centerWorker(TriMesh mesh) =>
    executeWorker(() => Modify.centerOnBed(mesh));

Future<TriMesh> duplicateWorker(TriMesh mesh, double offset) =>
    executeWorker(() => Modify.duplicate(mesh, offset: <double>[offset, 0, 0]));

Future<TriMesh> combineWorker(List<TriMesh> sources) =>
    executeWorker(() => Modify.combine(sources));

Future<TriMesh> patternWorker(TriMesh mesh, int cx, int cz, double gap) =>
    executeWorker(
      () => Modify.makePattern(mesh, countX: cx, countZ: cz, gap: gap),
    );

Future<TriMesh> primitiveWorker(TriMesh mesh, PrimitiveKind kind) =>
    executeWorker(() => Modify.fitPrimitive(mesh, kind));

Future<TriMesh> groupsWorker(TriMesh mesh) => executeWorker(() {
  final m = mesh.clone();
  m.faceGroups = FaceGroups.generate(m);
  return m;
});

Future<MeasureResult> measureWorker(TriMesh mesh) =>
    executeWorker(() => Modify.measure(mesh));

Future<double> clearanceWorker(TriMesh a, TriMesh b) =>
    executeWorker(() => Modify.clearance(a, b));

Future<TriMesh> stitchWorker(TriMesh mesh) =>
    executeWorker(() => Bridge.stitchNearest(mesh));

Future<Float64List> alignWorker(TriMesh source, TriMesh targetMesh) =>
    executeWorker(() => AlignTool.solve(source, targetMesh, iterations: 40));

Future<double> rmsWorker(TriMesh mesh, TriMesh targetMesh) =>
    executeWorker(() => AlignTool.rmsDistance(mesh, targetMesh));

Future<SupportResult> supportsWorker(
  TriMesh mesh,
  double angle,
  double density,
) => executeWorker(
  () => SupportGenerator.generate(
    mesh,
    settings: SupportSettings(overhangAngleDegrees: angle, density: density),
  ),
);

Future<ThicknessAnalysis> thicknessWorker(TriMesh mesh, double th) =>
    executeWorker(() => ThicknessAnalysis.run(mesh, threshold: th));

Future<OverhangAnalysis> overhangWorker(TriMesh mesh, double angle) =>
    executeWorker(() => OverhangAnalysis.run(mesh, angleDegrees: angle));

Future<StabilityAnalysis> stabilityWorker(TriMesh mesh) =>
    executeWorker(() => StabilityAnalysis.run(mesh));

Future<DeviationAnalysis> deviationWorker(
  TriMesh mesh,
  TriMesh referenceMesh,
) => executeWorker(
  () =>
      DeviationAnalysis.run(mesh, referenceMesh, maxSamples: mesh.vertexCount),
);

Future<List<MeshDefect>> inspectWorker(TriMesh mesh) =>
    executeWorker(() => MeshInspector.scan(mesh));

Future<TriMesh> repairWorker(TriMesh mesh) => executeWorker(() {
  var m = mesh;
  m = Weld.weldVertices(m, tolerance: m.bounds().diagonal * 1e-5);
  Weld.removeDuplicateFaces(m);
  m = MeshInspector.splitNonManifold(m);
  m = HoleFiller.fill(m, mode: HoleFillMode.smooth);
  return m;
});

Future<List<MixObject>> readMixWorker(Uint8List bytes) =>
    executeWorker(() => MixIO.read(bytes));

Future<TriMesh> readMeshWorker(String path, Uint8List bytes) => executeWorker(
  () => path.toLowerCase().endsWith('.obj')
      ? MeshIO.readFile(path)
      : MeshIO.readBytes(path, bytes),
);

Future<Uint8List> writeMeshWorker(String path, TriMesh mesh) =>
    executeWorker(() => MeshIO.writeBytes(path, mesh));

Future<PreparedMeshExport> prepareMeshExportWorker(String path, TriMesh mesh) =>
    executeWorker(() => MeshIO.prepareExport(path, mesh));

Future<DesktopRenderFrame> renderWorker(
  List<RenderObject> objects,
  Camera camera,
  RenderOptions options, {
  RenderBackendPreference preference = RenderBackendPreference.auto,
}) => executeWorker(
  () => renderDesktopFrame(objects, camera, options, preference: preference),
);

Future<ScanReport> scanInspectWorker(
  TriMesh mesh,
  PrintProfile profile,
  double area,
) => executeWorker(
  () => ScanWorkflow.inspect(mesh, profile: profile, fragmentArea: area),
);
Future<ScanEditResult> scanEditWorker(
  TriMesh mesh,
  ScanStep step,
  Uint8List? mask,
) => executeWorker(() => ScanRecipe.apply(mesh, step, selection: mask));
Future<SurfaceDeviation> scanDeviationWorker(
  TriMesh original,
  TriMesh changed,
) => executeWorker(() => SurfaceDeviation.measure(original, changed));
Future<String> fingerprintWorker(TriMesh mesh) =>
    executeWorker(() => meshFingerprint(mesh));
Future<SliceResult> sliceWorker(TriMesh mesh, double layer) =>
    executeWorker(() => Slicer.slice(mesh, layerHeight: layer));
Future<TriMesh> discardWorker(TriMesh mesh, Uint8List mask) => executeWorker(
  () => mesh.extractFaces([
    for (var f = 0; f < mesh.faceCount; f++)
      if (mask[f] == 0) f,
  ]),
);
Future<TriMesh> denoiseWorker(
  TriMesh mesh,
  Uint8List mask,
  double displacement,
) => executeWorker(
  () => ScanWorkflow.denoise(
    mesh,
    faceMask: mask,
    maximumDisplacement: displacement,
  ),
);
