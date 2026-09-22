import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/chat_page.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/utils/reasoning_pref.dart';
import 'package:continuum_chat/widgets/thinking_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatStore.cache = null;
    ReasoningPref.show.value = true;
  });

  tearDown(() {
    ChatStore.cache = null;
    ReasoningPref.show.value = true;
  });

  testWidgets(
    'long thinking card keeps its header fixed in a reversed lazy chat list',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      await binding.setSurfaceSize(const Size(375, 720));

      const targetReply = 'anchor-target-final-reply';
      final longReasoning = List.filled(
        180,
        '这是一段足够长的思考内容，用于验证展开和收起时的局部视觉锚点。',
      ).join();
      ChatStore.cache = [
        for (var i = 0; i < 70; i++)
          if (i == 32)
            ChatMessage(
              role: 'assistant',
              content: targetReply,
              reasoning: longReasoning,
              reasonings: [longReasoning],
            )
          else
            ChatMessage(
              role: i.isEven ? 'user' : 'assistant',
              content: 'viewport-filler-$i with enough height for lazy layout',
            ),
      ];

      await tester.pumpWidget(const MaterialApp(home: ChatPage()));
      await tester.pump();
      await tester.pump();

      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text(targetReply),
        280,
        scrollable: list,
        maxScrolls: 60,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text(targetReply)),
        alignment: 0.55,
      );
      await tester.pumpAndSettle();

      final card = find.byType(ThinkingCard);
      expect(card, findsOneWidget);
      final header = find.descendant(of: card, matching: find.text('想过'));
      expect(header, findsOneWidget);
      final collapsedDy = tester.getTopLeft(header).dy;
      expect(collapsedDy, inInclusiveRange(80, 560));

      await tester.tap(header);
      await tester.pump();
      expect(header, findsOneWidget);
      expect(
        (tester.getTopLeft(header).dy - collapsedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      await tester.pumpAndSettle();

      expect(find.text(longReasoning), findsOneWidget);
      expect(
        (tester.getTopLeft(header).dy - collapsedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      expect(
        find.descendant(of: card, matching: find.byType(AnimatedSize)),
        findsNothing,
      );
      expect(
        find.descendant(of: card, matching: find.byType(TweenAnimationBuilder)),
        findsNothing,
      );

      final expandedDy = tester.getTopLeft(header).dy;
      await tester.tap(header);
      await tester.pump();
      expect(header, findsOneWidget);
      expect(
        (tester.getTopLeft(header).dy - expandedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      await tester.pumpAndSettle();

      expect(find.text(longReasoning), findsNothing);
      expect(
        (tester.getTopLeft(header).dy - expandedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tool process expanders keep their headers fixed in a reversed lazy chat list',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      await binding.setSurfaceSize(const Size(375, 720));

      const targetReply = 'tool-anchor-target-final-reply';
      final longToolResult = List.filled(
        90,
        '工具返回的一段较长内容，用来验证展开和收起时聊天列表不能乱跳。',
      ).join('\n');
      ChatStore.cache = [
        for (var i = 0; i < 70; i++)
          if (i == 32)
            ChatMessage(
              role: 'assistant',
              content: targetReply,
              parts: [
                ChatMessagePart(
                  type: ChatMessagePartType.reasoning,
                  text: '先判断应该调用哪个工具。',
                  round: 1,
                  status: 'done',
                ),
                ChatMessagePart(
                  type: ChatMessagePartType.tool,
                  round: 1,
                  status: 'done',
                  tools: [
                    ChatToolCallPart(
                      name: 'search',
                      arguments: const {'query': 'viewport anchor'},
                      result: longToolResult,
                    ),
                  ],
                ),
                ChatMessagePart(
                  type: ChatMessagePartType.text,
                  text: targetReply,
                ),
              ],
            )
          else
            ChatMessage(
              role: i.isEven ? 'user' : 'assistant',
              content:
                  'tool-viewport-filler-$i with enough height for lazy layout',
            ),
      ];

      await tester.pumpWidget(const MaterialApp(home: ChatPage()));
      await tester.pump();
      await tester.pump();

      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text(targetReply),
        280,
        scrollable: list,
        maxScrolls: 60,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text(targetReply)),
        alignment: 0.55,
      );
      await tester.pumpAndSettle();

      final processHeader = find.text('处理过 · 搜索');
      expect(processHeader, findsOneWidget);
      final processCollapsedDy = tester.getTopLeft(processHeader).dy;
      expect(processCollapsedDy, inInclusiveRange(80, 560));

      await tester.tap(processHeader);
      await tester.pump();
      expect(
        (tester.getTopLeft(processHeader).dy - processCollapsedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      await tester.pumpAndSettle();
      expect(
        (tester.getTopLeft(processHeader).dy - processCollapsedDy).abs(),
        lessThanOrEqualTo(1.5),
      );

      final toolHeader = find.text('处理好了 · 搜索');
      expect(toolHeader, findsOneWidget);
      final toolCollapsedDy = tester.getTopLeft(toolHeader).dy;
      await tester.tap(toolHeader);
      await tester.pump();
      expect(
        (tester.getTopLeft(toolHeader).dy - toolCollapsedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      await tester.pumpAndSettle();
      expect(
        (tester.getTopLeft(toolHeader).dy - toolCollapsedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      expect(find.text(longToolResult), findsOneWidget);

      final toolExpandedDy = tester.getTopLeft(toolHeader).dy;
      await tester.tap(toolHeader);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        (tester.getTopLeft(toolHeader).dy - toolExpandedDy).abs(),
        lessThanOrEqualTo(1.5),
      );

      final collapseBar = find.text('收起');
      expect(collapseBar, findsOneWidget);
      await tester.ensureVisible(collapseBar);
      await tester.pumpAndSettle();
      final processExpandedDy = tester.getTopLeft(processHeader).dy;
      await tester.tap(collapseBar);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsNothing);
      expect(
        (tester.getTopLeft(processHeader).dy - processExpandedDy).abs(),
        lessThanOrEqualTo(1.5),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
