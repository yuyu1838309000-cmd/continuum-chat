import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/chat_api.dart';
import 'package:continuum_chat/widgets/chat_scene_mode_control.dart';

void main() {
  Future<void> pumpControl(
    WidgetTester tester, {
    required Future<SceneMode?> Function() loadMode,
    required Future<SceneMode?> Function(SceneMode) saveMode,
    double width = 375,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('AI 助手'),
            actions: [
              ChatSceneModeControl(loadMode: loadMode, saveMode: saveMode),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.search_rounded),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('unknown is icon-only and both choices are available', (
    tester,
  ) async {
    await pumpControl(
      tester,
      loadMode: () async => SceneMode.unknown,
      saveMode: (mode) async => mode,
    );

    final button = find.byKey(const ValueKey('scene-mode-button'));
    expect(button, findsOneWidget);
    expect(find.byTooltip('相处模式：未选择'), findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.byType(Text)),
      findsNothing,
    );
    expect(find.text('相处模式'), findsNothing);
    expect(find.text('未选择'), findsNothing);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('scene-mode-option-online')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('scene-mode-option-face_to_face')),
      findsOneWidget,
    );
    expect(find.text('相处模式'), findsOneWidget);
    expect(find.text('线上'), findsOneWidget);
    expect(find.text('面对面'), findsOneWidget);
  });

  testWidgets('successful switches update the icon state tooltip', (
    tester,
  ) async {
    final saved = <SceneMode>[];
    await pumpControl(
      tester,
      loadMode: () async => SceneMode.unknown,
      saveMode: (mode) async {
        saved.add(mode);
        return mode;
      },
    );

    await tester.tap(find.byKey(const ValueKey('scene-mode-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scene-mode-option-online')));
    await tester.pumpAndSettle();

    expect(saved, [SceneMode.online]);
    expect(find.byTooltip('相处模式：线上'), findsOneWidget);
    expect(find.text('线上'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('scene-mode-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('scene-mode-option-face_to_face')),
    );
    await tester.pumpAndSettle();

    expect(saved, [SceneMode.online, SceneMode.faceToFace]);
    expect(find.byTooltip('相处模式：面对面'), findsOneWidget);
    expect(find.text('面对面'), findsNothing);
  });

  testWidgets('failed switch keeps the old mode and gives brief feedback', (
    tester,
  ) async {
    await pumpControl(
      tester,
      loadMode: () async => SceneMode.online,
      saveMode: (_) async => null,
    );

    await tester.tap(find.byKey(const ValueKey('scene-mode-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('scene-mode-option-face_to_face')),
    );
    await tester.pump();

    expect(find.byTooltip('相处模式：线上'), findsOneWidget);
    expect(find.text('切换失败，请稍后再试'), findsOneWidget);
  });

  testWidgets('AppBar control does not overflow supported widths', (
    tester,
  ) async {
    for (final width in [320.0, 375.0, 414.0]) {
      await pumpControl(
        tester,
        width: width,
        loadMode: () async => SceneMode.faceToFace,
        saveMode: (mode) async => mode,
      );
      expect(tester.takeException(), isNull, reason: 'overflowed at $width px');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
