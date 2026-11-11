import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native scan preview preserves original, profile and reports across reopen',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'mmx-native-scan-',
      );
      final state = StudioState();
      final boundary = GlobalKey();
      try {
        final seed = TriMesh(
          Float32List.fromList([-10, -10, -10, 10, 10, 10]),
          Uint32List(0),
        );
        final body = Modify.fitPrimitive(seed, PrimitiveKind.sphere);
        final fragment = body.clone()
          ..transform(multiply4(translation4(15, 0, 0), scale4(.02)));
        final input = '${directory.path}/扫描.obj';
        await File(input).writeAsBytes(
          MeshIO.writeBytes(input, Modify.combine([body, fragment])),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: RepaintBoundary(
              key: boundary,
              child: StudioScreen(state: state, enableRecovery: false),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await state.importPath(input);
        state.printProfile = const PrintProfile(
          width: 220,
          depth: 180,
          height: 250,
        );
        state.scanFragmentArea = 10;
        await state.previewScan(ScanStep('fragments', {'areaMm2': 10}));
        await tester.pumpAndSettle();
        if (find.text('Apply scan edit').evaluate().isEmpty) {
          await tester.tap(find.byTooltip('Tool properties'));
          await tester.pumpAndSettle();
        }
        expect(state.scanPreview, isNotNull, reason: state.status);
        expect(state.frame, isNotNull);
        state.showScanOriginal(true);
        await state.render();
        await tester.pumpAndSettle();
        expect(state.doc.objects, hasLength(1));
        state.showScanOriginal(false);
        await state.render();
        await tester.pumpAndSettle();
        final screenshot = Platform.environment['MMX_SCAN_SCREENSHOT'];
        if (screenshot != null) {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(screenshot).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        }
        await state.applyScanPreview();
        await tester.pumpAndSettle();
        expect(
          state.activeMesh!.faceCount,
          body.faceCount,
          reason: state.status,
        );
        expect(state.doc.objects, hasLength(2));
        expect(state.doc.byId(state.selected!.scanSourceId!)!.locked, isTrue);
        final project = '${directory.path}/项目.mmx';
        expect(await state.saveProject(project), isTrue, reason: state.status);
        expect(await state.openProject(project), isTrue, reason: state.status);
        expect(state.printProfile.depth, 180);
        expect(state.selected!.scanHistory, hasLength(1));
        final report = '${directory.path}/report.json';
        expect(
          await state.exportScanData(report),
          isTrue,
          reason: state.status,
        );
        final json = jsonDecode(await File(report).readAsString());
        expect(json['originalMeshSha256'], hasLength(64));
        expect(json['preflight']['profile']['widthMm'], 220);
        final output = '${directory.path}/print.stl';
        await state.exportSelected(output);
        final mesh = MeshIO.readFile(output);
        expect(MeshTopology(mesh).boundaryEdges(), isEmpty);
        expect(MeshTopology(mesh).nonManifoldEdges(), isEmpty);
        expect(mesh.signedVolume(), closeTo(body.signedVolume(), .01));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        state.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
