import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:continuum_chat/services/tts_api.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';
import 'package:continuum_chat/models/message.dart';

void main() {
  setUp(() {
    TtsConfig.instance.readAloud = true;
  });

  testWidgets('custom toolbar shows Chinese buttons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              message: ChatMessage(role: 'assistant', content: '这是测试文本'),
              isMe: false,
              onCopyAll: () {},
              onRegenerate: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    // 长按文字
    await tester.longPress(find.text('这是测试文本'));
    await tester.pumpAndSettle();
    // 断言：有中文按钮，没有英文 Copy
    expect(find.text('复制'), findsWidgets);
    expect(find.text('全选'), findsWidgets);
    expect(find.text('复制整条'), findsOneWidget);
    expect(find.text('语音播放'), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Select all'), findsNothing);
  });

  testWidgets('assistant bubble does not render persistent TTS icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(role: 'assistant', content: '这是测试文本'),
            isMe: false,
            showTimestamp: false,
          ),
        ),
      ),
    );

    expect(find.byIcon(LucideIcons.volume_2), findsNothing);
    expect(find.byIcon(LucideIcons.volume_x), findsNothing);
  });

  testWidgets('user toolbar does not show TTS action', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              message: ChatMessage(role: 'user', content: '这是我的消息'),
              isMe: true,
              onCopyAll: () {},
              onEdit: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('这是我的消息'));
    await tester.pumpAndSettle();

    expect(find.text('复制整条'), findsOneWidget);
    expect(find.text('编辑重发'), findsOneWidget);
    expect(find.text('语音播放'), findsNothing);
    expect(find.text('停止播放'), findsNothing);
  });
}
