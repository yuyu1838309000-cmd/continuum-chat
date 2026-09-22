import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/assistant_hub_page.dart';
import 'package:continuum_chat/pages/personal_space_page.dart';
import 'package:continuum_chat/pages/together_hub_page.dart';
import 'package:continuum_chat/pages/toolbox_page.dart';

void _expectTappableEntry(String label) {
  expect(
    find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
    findsOneWidget,
  );
}

void main() {
  testWidgets('Assistant Hub exposes its person and content destinations', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantHubPage(moodLoader: ({onCached}) async => null),
      ),
    );

    expect(find.text('AI 助手'), findsWidgets);
    expect(
      find.byKey(const ValueKey('assistant_profile_hero')),
      findsOneWidget,
    );
    for (final label in ['当前心情', '个人内容', '相处偏好']) {
      expect(find.text(label), findsOneWidget);
      _expectTappableEntry(label);
    }
  });

  testWidgets('Together Hub exposes its five existing destinations', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: TogetherHubPage()));

    expect(find.text('一起'), findsOneWidget);
    for (final label in ['小家', '一起听', '一起读', '旅行', '提问瓶']) {
      expect(find.text(label), findsOneWidget);
      _expectTappableEntry(label);
    }
  });

  testWidgets('personal content no longer includes travel', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalSpacePage(
          diaryLoader: ({onCached}) async => const [],
          whisperLoader: ({onCached}) async => const [],
          contemplationCountLoader: ({onCached}) async => 0,
        ),
      ),
    );

    expect(find.text('个人内容'), findsOneWidget);
    for (final label in ['日记', '想说的话', '沉思室']) {
      expect(find.text(label), findsOneWidget);
      _expectTappableEntry(label);
    }
    expect(find.text('旅行'), findsNothing);
  });

  testWidgets('Ability reuses Toolbox content with an alternate title', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ToolboxPage(title: '能力')));

    expect(find.text('能力'), findsOneWidget);
    expect(find.text('插件'), findsOneWidget);
    expect(find.text('插件市场'), findsNothing);
    expect(find.text('我的插件'), findsNothing);

    await tester.pumpWidget(const MaterialApp(home: ToolboxPage()));
    expect(find.text('工具箱'), findsOneWidget);
  });
}
