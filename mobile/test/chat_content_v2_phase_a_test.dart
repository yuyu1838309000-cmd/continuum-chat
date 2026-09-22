import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/chat_page.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:continuum_chat/utils/chat_process_copy.dart';
import 'package:continuum_chat/utils/reasoning_pref.dart';
import 'package:continuum_chat/utils/timestamp_pref.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';
import 'package:continuum_chat/widgets/thinking_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatStore.cache = null;
    ReasoningPref.show.value = true;
    TimestampPref.show.value = false;
  });

  tearDown(() {
    ChatStore.cache = null;
    ReasoningPref.show.value = true;
    TimestampPref.show.value = true;
  });
  test('process copy hides backend jargon without hiding state', () {
    expect(chatToolDisplayName('termux'), '手机操作');
    expect(
      chatProcessSectionLabel(
        failed: false,
        active: true,
        hasTool: true,
        stepCount: 3,
      ),
      '正在处理…',
    );
    expect(
      chatProcessSectionLabel(
        failed: false,
        active: false,
        hasTool: true,
        stepCount: 2,
        toolNames: const ['搜索'],
      ),
      '处理过 · 搜索',
    );
    expect(
      chatProcessSectionLabel(
        failed: true,
        active: false,
        hasTool: true,
        stepCount: 2,
      ),
      '这段没做完 · 2步',
    );
    expect(
      chatToolStepLabel(
        status: 'running',
        running: true,
        deviceRunning: true,
        toolNames: const ['手机操作'],
      ),
      '正在操作手机…',
    );
    expect(
      chatToolStepLabel(
        status: 'failed',
        running: false,
        deviceRunning: false,
        toolNames: const ['搜索'],
      ),
      '搜索没做完',
    );
    expect(chatToolDoneDisplayLabel(ChatMessage.toolDoneLabel), '处理好了');
  });

  testWidgets('thinking and standalone done states read like chat', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ThinkingCard(text: '先看看', active: true, expanded: false),
              MessageBubble.toolDoneCard(
                ThemeData.light(),
                label: ChatMessage.toolDoneLabel,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('在想'), findsOneWidget);
    expect(find.text('我在想'), findsNothing);
    expect(find.text('处理好了'), findsOneWidget);
    expect(find.text(ChatMessage.toolDoneLabel), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ThinkingCard(text: '先看看', active: false, expanded: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('想过'), findsOneWidget);
    expect(find.text('先看看'), findsOneWidget);
  });

  testWidgets('active expanded reasoning avoids selectable relayout churn', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ThinkingCard(text: '正在持续增长的思考内容', active: true, expanded: true),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在持续增长的思考内容'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ThinkingCard(text: '已经结束的思考内容', active: false, expanded: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('completed process keeps details behind two light taps', (
    tester,
  ) async {
    ChatStore.cache = [_processMessage()];
    await tester.pumpWidget(const MaterialApp(home: ChatPage()));
    await tester.pump();

    expect(find.text('处理过 · 搜索'), findsOneWidget);
    expect(find.textContaining('工具调用'), findsNothing);
    expect(find.text('调用内容'), findsNothing);
    expect(find.text('调用结果'), findsNothing);

    await tester.tap(find.text('处理过 · 搜索'));
    await tester.pumpAndSettle();
    expect(find.text('想过'), findsOneWidget);
    expect(find.text('处理好了 · 搜索'), findsOneWidget);
    expect(find.text('输入'), findsNothing);
    expect(find.text('结果'), findsNothing);

    await tester.ensureVisible(find.text('处理好了 · 搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理好了 · 搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('输入'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
    expect(find.textContaining('天气'), findsOneWidget);
    expect(find.textContaining('晴'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('process presentation fits phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      for (final theme in [appTheme.light, appTheme.dark]) {
        ChatStore.cache = [_processMessage(long: true)];
        await tester.pumpWidget(
          MaterialApp(theme: theme, home: const ChatPage()),
        );
        await tester.pump();
        expect(find.text('处理过 · 搜索'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '${theme.brightness.name} ${width.toInt()}px',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });
}

ChatMessage _processMessage({bool long = false}) {
  return ChatMessage(
    role: 'assistant',
    content: long ? '这是一段用于窄屏回归的较长最终回复文字。' : '处理完了',
    runtimeStatus: 'completed',
    parts: [
      ChatMessagePart(
        type: ChatMessagePartType.reasoning,
        round: 1,
        status: 'done',
        text: long ? '先想一想这段较长的过程文本会不会在窄屏溢出。' : '先看看',
      ),
      ChatMessagePart(
        type: ChatMessagePartType.tool,
        round: 1,
        status: 'done',
        tools: const [
          ChatToolCallPart(
            name: 'search',
            arguments: {'query': '天气'},
            result: '{"weather":"晴"}',
          ),
        ],
      ),
      ChatMessagePart(
        type: ChatMessagePartType.text,
        round: 1,
        status: 'done',
        text: long ? '这是一段用于窄屏回归的较长最终回复文字。' : '处理完了',
      ),
    ],
  );
}
