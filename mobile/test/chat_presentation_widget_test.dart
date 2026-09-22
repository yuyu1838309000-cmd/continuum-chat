import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/chat_page.dart';
import 'package:continuum_chat/pages/chat_reply_presentation.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/utils/timestamp_pref.dart';
import 'package:continuum_chat/utils/token_usage.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('active draining and idle composer states are exact', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 720));
      for (final state in ChatComposerRuntimeState.values) {
        var sends = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ChatComposerSendButton(
                  state: state,
                  hasContent: true,
                  busy: false,
                  onSend: () => sends += 1,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final expectedTooltip = switch (state) {
          ChatComposerRuntimeState.active => '正在回复…',
          ChatComposerRuntimeState.draining => '回复还在显示…',
          ChatComposerRuntimeState.idle => '发送',
        };
        expect(find.byTooltip(expectedTooltip), findsOneWidget);
        final button = tester.widget<IconButton>(find.byType(IconButton));
        switch (state) {
          case ChatComposerRuntimeState.active ||
              ChatComposerRuntimeState.draining:
            expect(find.byIcon(LucideIcons.x), findsNothing);
            expect(find.byIcon(LucideIcons.arrow_up), findsNothing);
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            expect(button.onPressed, isNull);
          case ChatComposerRuntimeState.idle:
            expect(find.byIcon(LucideIcons.arrow_up), findsOneWidget);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(button.onPressed, isNotNull);
            await tester.tap(find.byType(IconButton));
            expect(sends, 1);
        }
        expect(
          tester.takeException(),
          isNull,
          reason: '${width.toInt()} $state',
        );
      }
    }
  });

  testWidgets('terminal-before-pacing stays draining until reveal completes', (
    tester,
  ) async {
    final reply = ChatMessage(
      role: 'assistant',
      content: '',
      time: DateTime(2026, 9, 1, 12, 34),
      usage: const MessageUsage(
        promptTokens: 100,
        cacheHit: 50,
        cacheMiss: 50,
        completionTokens: 20,
      ),
    );
    final presentation = ChatReplyPresentation()..bind(reply);
    final part = ChatMessagePart(type: ChatMessagePartType.text, text: '完整回复');
    reply
      ..content = part.text
      ..parts = [part]
      ..runtimeStatus = 'completed';
    final delta = presentation.captureNewText(reply).single;
    presentation.markTerminal();

    Future<void> pumpState() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ChatComposerSendButton(
                state: presentation.hasUnrevealedText
                    ? ChatComposerRuntimeState.draining
                    : ChatComposerRuntimeState.idle,
                hasContent: true,
                busy: false,
                onSend: () {},
              ),
              MessageBubble(
                message: reply,
                isMe: false,
                streaming: presentation.hasUnrevealedText,
                showTimestamp: true,
                showTokenUsage: true,
              ),
            ],
          ),
        ),
      ),
    );

    await pumpState();
    expect(find.byTooltip('回复还在显示…'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    expect(find.text('50%'), findsNothing);
    expect(find.text('[09-01 12:34]'), findsNothing);

    presentation.reveal(delta.text, delta.text, target: delta.target);
    await pumpState();
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('[09-01 12:34]'), findsOneWidget);
  });

  testWidgets('idle composer stays disabled without sendable content', (
    tester,
  ) async {
    Future<void> pump({required bool hasContent, required bool busy}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatComposerSendButton(
                state: ChatComposerRuntimeState.idle,
                hasContent: hasContent,
                busy: busy,
                onSend: () {},
              ),
            ),
          ),
        );

    await pump(hasContent: false, busy: false);
    expect(find.byIcon(LucideIcons.arrow_up), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );

    await pump(hasContent: true, busy: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
  });

  testWidgets('failed user send exposes red recovery affordance', (
    tester,
  ) async {
    var recoveryTaps = 0;
    final message = ChatMessage(
      role: 'user',
      content: '没有发出去',
      sendFailed: true,
      sendError: 'generation_not_accepted',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            isMe: true,
            onSendFailedTap: () => recoveryTaps += 1,
          ),
        ),
      ),
    );

    final recovery = find.byTooltip('重新编辑');
    expect(recovery, findsOneWidget);
    final icon = tester.widget<Icon>(find.byIcon(LucideIcons.circle_alert));
    expect(icon.color, Theme.of(tester.element(recovery)).colorScheme.error);
    await tester.tap(recovery);
    expect(recoveryTaps, 1);
  });

  testWidgets('partial failed assistant reply stays visible and marked', (
    tester,
  ) async {
    final message = ChatMessage(
      role: 'assistant',
      content: '已经显示的部分回复',
      runtimeStatus: 'failed',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageBubble(message: message, isMe: false)),
      ),
    );

    expect(find.text('已经显示的部分回复'), findsOneWidget);
    expect(find.text('回复中断'), findsOneWidget);
    expect(find.byIcon(LucideIcons.circle_alert), findsOneWidget);
  });

  testWidgets(
    'structured partial failure marks the final visible bubble once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final reply = ChatMessage(
        role: 'assistant',
        content: '第一段第二段',
        runtimeStatus: 'failed',
        parts: [
          ChatMessagePart(type: ChatMessagePartType.text, text: '第一段'),
          ChatMessagePart(type: ChatMessagePartType.text, text: '第二段'),
        ],
      );
      ChatStore.cache = [reply];
      addTearDown(() => ChatStore.cache = null);

      await tester.pumpWidget(const MaterialApp(home: ChatPage()));
      await tester.pump();

      expect(find.text('第一段'), findsOneWidget);
      expect(find.text('第二段'), findsOneWidget);
      expect(find.text('回复中断'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'usage belongs once to the final non-empty canonical text bubble',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      TokenUsagePref.show.value = true;
      TimestampPref.show.value = false;
      final reply = ChatMessage(
        role: 'assistant',
        content: '第一段\n最终段',
        runtimeStatus: 'completed',
        usage: const MessageUsage(
          promptTokens: 100,
          cacheHit: 50,
          cacheMiss: 50,
          completionTokens: 20,
        ),
        parts: [
          ChatMessagePart(type: ChatMessagePartType.text, text: '第一段'),
          ChatMessagePart(type: ChatMessagePartType.reasoning, text: '思考'),
          ChatMessagePart(
            type: ChatMessagePartType.tool,
            tools: const [ChatToolCallPart(name: 'device_status')],
          ),
          ChatMessagePart(type: ChatMessagePartType.text, text: '最终段'),
          ChatMessagePart(type: ChatMessagePartType.text),
        ],
      );
      ChatStore.cache = [reply];
      addTearDown(() {
        ChatStore.cache = null;
        TokenUsagePref.show.value = false;
        TimestampPref.show.value = true;
      });

      await tester.pumpWidget(const MaterialApp(home: ChatPage()));
      await tester.pump();

      final usageBubbles = tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .where((bubble) => bubble.message.usage != null)
          .toList();
      expect(usageBubbles, hasLength(1));
      expect(usageBubbles.single.message.content, '最终段');
      expect(find.text('50%'), findsOneWidget);
      expect(
        tester
            .widgetList<MessageBubble>(find.byType(MessageBubble))
            .where(
              (bubble) =>
                  bubble.message.content.isEmpty &&
                  bubble.message.usage != null,
            ),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
