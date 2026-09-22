import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/widgets/thinking_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'collapse removes long reasoning body without stale blank extent',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      await binding.setSurfaceSize(const Size(375, 900));

      var expanded = true;
      late StateSetter update;
      final longText = List.filled(30, '这是一段很长的思考内容，用来撑高卡片。').join();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Align(
                  alignment: Alignment.topLeft,
                  child: ThinkingCard(
                    text: longText,
                    active: false,
                    expanded: expanded,
                    onToggle: () => update(() => expanded = !expanded),
                  ),
                );
              },
            ),
          ),
        ),
      );

      final expandedHeight = tester.getSize(find.byType(ThinkingCard)).height;
      expect(expandedHeight, greaterThan(120));
      expect(find.text('收起'), findsOneWidget);

      await tester.tap(find.text('收起'));
      await tester.pump();

      final collapsedHeight = tester.getSize(find.byType(ThinkingCard)).height;
      expect(collapsedHeight, lessThan(60));
      expect(find.text(longText), findsNothing);
      expect(find.text('收起'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settling an expanded active card keeps the bottom collapse control',
    (tester) async {
      var active = true;
      late StateSetter update;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ThinkingCard(
                  text: '正在增长的 reasoning',
                  active: active,
                  expanded: true,
                  onToggle: () {},
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('收起'), findsOneWidget);
      expect(find.text('在想'), findsOneWidget);

      update(() => active = false);
      await tester.pump();

      expect(find.text('想过'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settled reasoning keeps selection and copy-all actions', (
    tester,
  ) async {
    var copiedAll = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThinkingCard(
            text: '可选择和复制的完整思考内容',
            expanded: true,
            onCopyAll: () => copiedAll = true,
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await tester.longPress(find.text('可选择和复制的完整思考内容'));
    await tester.pumpAndSettle();

    expect(find.text('复制整条'), findsOneWidget);
    await tester.tap(find.text('复制整条'));
    await tester.pump();
    expect(copiedAll, isTrue);
  });
}
