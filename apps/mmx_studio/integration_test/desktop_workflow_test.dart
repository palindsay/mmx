import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/screen.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native desktop import edit undo project reopen and mesh export',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('mmx-desktop-');
      final state = StudioState();
      try {
        // Exercises registered native plugins without interactive OS dialogs.
        final support = await getApplicationSupportDirectory();
        expect(support.path, isNotEmpty);
        final model = Modify.fitPrimitive(
          TriMesh(Float32List.fromList([-5, -5, -5, 5, 5, 5]), Uint32List(0)),
          PrimitiveKind.sphere,
        );
        final input = File('${directory.path}/模型 input.obj');
        await input.writeAsBytes(MeshIO.writeBytes(input.path, model));
        await tester.pumpWidget(
          MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
        );
        await tester.pumpAndSettle();
        expect(find.text('MESH STUDIO'), findsOneWidget);
        expect(state.doc.objects, isEmpty);
        expect(find.text('Empty project'), findsOneWidget);
        await state.importPath(input.path, unitScale: 10);
        await tester.pumpAndSettle();
        expect(state.selected, isNotNull, reason: state.status);
        expect(state.activeMesh!.bounds().extentX, closeTo(100, .001));
        final before = state.activeMesh!.faceCount;
        state.reducePercent = .5;
        await state.doReduce();
        expect(
          state.activeMesh!.faceCount,
          lessThan(before),
          reason: state.status,
        );
        final reduced = state.activeMesh!.faceCount;
        await state.undo();
        expect(state.activeMesh!.faceCount, before);
        await state.redo();
        expect(state.activeMesh!.faceCount, reduced);
        final project = '${directory.path}/场景.mmx';
        expect(await state.saveProject(project), true, reason: state.status);
        await state.transformSelected(translation4(20, 0, 0));
        expect(state.dirty, true);
        expect(await state.openProject(project), true, reason: state.status);
        expect(state.selected!.transform[12], 0);
        final output = '${directory.path}/output.stl';
        await state.exportSelected(output);
        final exported = MeshIO.readBytes(
          output,
          await File(output).readAsBytes(),
        );
        expect(exported.validate(), isEmpty);
        expect(exported.faceCount, reduced);
        expect(MeshTopology(exported).boundaryLoops(), isEmpty);
        expect(MeshTopology(exported).nonManifoldEdges(), isEmpty);
        await tester.tap(find.byTooltip('Project'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New project'));
        await tester.pumpAndSettle();
        expect(state.doc.objects, isEmpty);
        expect(state.doc.canUndo, false);
        expect(state.projectPath, isNull);
        expect(find.text('Empty project'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        state.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
