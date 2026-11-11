import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/panels.dart';

String keyboardFocusDescription() {
  final focus = FocusManager.instance.primaryFocus;
  final ancestors = <String>[];
  focus?.context?.visitAncestorElements((element) {
    ancestors.add('${element.widget.runtimeType}(${element.widget.key})');
    return ancestors.length < 8;
  });
  return '$focus; ancestors: ${ancestors.join(' > ')}';
}

/// Send Tab through both keyboard stages used by a native macOS text field.
/// IntegrationTestWidgetsFlutterBinding leaves TestTextInput unregistered, so
/// its synthetic keys cannot invoke Cocoa's NSTextInputContext. Flutter defers
/// macOS EditableText Tab to that IME, which sends the insertTab: selector back
/// over flutter/textinput. Simulate that missing platform message only; never
/// request button focus or invoke its action directly.
Future<void> tabFromFieldToButton(
  WidgetTester tester, {
  required Finder field,
  required Finder button,
}) async {
  final editable = tester.widget<EditableText>(
    find.descendant(of: field, matching: find.byType(EditableText)),
  );
  debugPrint(
    'Before Tab: value=${editable.controller.value}; '
    'inputMock=${tester.testTextInput.isRegistered}; '
    '${keyboardFocusDescription()}',
  );
  expect(editable.focusNode.hasPrimaryFocus, isTrue);
  expect(tester.widget<ButtonStyleButton>(button).enabled, isTrue);
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
  if (defaultTargetPlatform == TargetPlatform.macOS &&
      !tester.testTextInput.isRegistered) {
    expect(handled, isFalse, reason: 'macOS forwards text-field Tab to Cocoa');
    expect(editable.focusNode.hasPrimaryFocus, isTrue);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        const MethodCall('TextInputClient.performSelectors', [
          -1, // Flutter's debug test client, also used by tester.enterText.
          ['insertTab:'],
        ]),
      ),
      (response) {
        expect(response, isNotNull);
        SystemChannels.textInput.codec.decodeEnvelope(response!);
      },
    );
    await tester.pumpAndSettle();
  }
  debugPrint('After Tab: ${keyboardFocusDescription()}');
  final target = tester.element(button);
  final focusedContext = FocusManager.instance.primaryFocus?.context;
  var buttonHasFocus = focusedContext == target;
  focusedContext?.visitAncestorElements((element) {
    if (element == target) buttonHasFocus = true;
    return !buttonHasFocus;
  });
  expect(
    buttonHasFocus,
    isTrue,
    reason: 'Tab must focus Apply before Enter: ${keyboardFocusDescription()}',
  );
}

/// Frame settlement alone can finish before an isolate releases its edit lock.
Future<void> settleStudioInteraction(
  WidgetTester tester,
  StudioState state,
) async {
  await tester.pump();
  for (var i = 0; i < 500 && state.interactionLocked; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(state.interactionLocked, isFalse, reason: state.status);
  await tester.pumpAndSettle();
}

/// Reach properties through the same affordance used in compact desktop windows.
Future<void> openPropertiesPanel(WidgetTester tester) async {
  final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
  final button = find.byTooltip('Tool properties');
  debugPrint(
    'Properties layout: ${tester.getSize(find.byType(Scaffold)).width} '
    'logical pixels; compact drawer: ${button.evaluate().isNotEmpty}',
  );
  if (button.evaluate().isNotEmpty && !scaffold.isEndDrawerOpen) {
    await tester.tap(button);
    await tester.pumpAndSettle();
  }
  expect(find.byType(PropertiesPanel), findsOneWidget);
}

/// Dismiss the compact drawer through its scrim before viewport pointer input.
Future<void> closePropertiesPanel(WidgetTester tester) async {
  final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
  if (!scaffold.isEndDrawerOpen) return;
  final screen = tester.getRect(find.byType(Scaffold));
  final drawer = tester.getRect(find.byType(Drawer));
  expect(drawer.left, greaterThan(screen.left));
  await tester.tapAt(Offset((screen.left + drawer.left) / 2, screen.center.dy));
  await tester.pumpAndSettle();
  expect(scaffold.isEndDrawerOpen, isFalse);
}
