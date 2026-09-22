import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/overview_drawer.dart';
import 'package:continuum_chat/utils/nickname.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

void main() {
  testWidgets('overview drawer keeps entries reachable on a compact screen', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => binding.setSurfaceSize(null));

    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 256,
              child: OverviewDrawer(
                onClose: () => events.add('close'),
                onOpenHistory: () => events.add('history'),
                onOpenMemory: () => events.add('memory'),
                onOpenAssistant: () => events.add('assistant'),
                onOpenTogether: () => events.add('together'),
                onOpenAbility: () => events.add('ability'),
                onOpenSettings: () => events.add('settings'),
                onStartNewChat: () => events.add('new'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['历史', '记忆', 'AI 助手', '一起', '能力']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final oldLabel in ['个人空间', '小家', '一起听', '一起读', '提问瓶']) {
      expect(find.text(oldLabel), findsNothing);
    }
    expect(find.bySemanticsLabel('设置'), findsOneWidget);
    expect(find.bySemanticsLabel('新对话'), findsOneWidget);
    expect(find.bySemanticsLabel('资料'), findsNothing);
    expect(find.byIcon(LucideIcons.chevron_right), findsNWidgets(5));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(NicknameManager.instance.name));
    expect(events, isEmpty);

    await tester.tap(find.bySemanticsLabel('改昵称'));
    await tester.pumpAndSettle();
    expect(find.text('改个名字'), findsOneWidget);
    expect(events, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    for (final (label, event) in [
      ('历史', 'history'),
      ('记忆', 'memory'),
      ('AI 助手', 'assistant'),
      ('一起', 'together'),
      ('能力', 'ability'),
    ]) {
      await tester.tap(find.text(label));
      expect(events, ['close', event]);
      events.clear();
    }

    await tester.tap(find.bySemanticsLabel('设置'));
    expect(events, ['close', 'settings']);

    events.clear();
    await tester.tap(find.bySemanticsLabel('新对话'));
    expect(events, ['close', 'new']);
  });
}
