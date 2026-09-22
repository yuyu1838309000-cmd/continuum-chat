import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';

void main() {
  Future<void> pumpBubble(
    WidgetTester tester,
    ChatMessage message, {
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: MessageBubble(
              message: message,
              isMe: message.role == 'user',
              showTimestamp: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('image OCR stays collapsed until explicitly opened', (
    tester,
  ) async {
    const hiddenText = '这段识别全文不该默认铺在聊天流里';
    await pumpBubble(
      tester,
      ChatMessage(
        role: 'assistant',
        content: '图片里的重点在图本身。',
        ocrText: hiddenText,
      ),
    );

    expect(find.text('识别到图片文字'), findsOneWidget);
    expect(find.text(hiddenText), findsNothing);

    await tester.tap(find.text('识别到图片文字'));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text(hiddenText), findsOneWidget);
  });

  testWidgets('file card reads like shared content metadata', (tester) async {
    await pumpBubble(
      tester,
      ChatMessage(
        role: 'user',
        content: '[文件]',
        fileUrl: 'https://example.com/report.pdf',
        fileName: '旅行计划.pdf',
        fileType: 'doc',
        fileSize: 2048,
      ),
    );

    expect(find.text('旅行计划.pdf'), findsOneWidget);
    expect(find.text('文档 · 2.0 KB'), findsOneWidget);
    expect(find.text('未知大小'), findsNothing);
  });
  testWidgets('quote remains readable without becoming a second card', (
    tester,
  ) async {
    await pumpBubble(
      tester,
      ChatMessage(role: 'assistant', content: '前面一句。\n> 这是一段引用。'),
    );

    expect(find.textContaining('前面一句'), findsOneWidget);
    expect(find.textContaining('这是一段引用'), findsOneWidget);
  });

  testWidgets('code uses a human label and keeps long-code expansion', (
    tester,
  ) async {
    final code = List.generate(14, (i) => 'line${i + 1}').join('\n');
    await pumpBubble(
      tester,
      ChatMessage(role: 'assistant', content: '```\n$code\n```'),
    );

    expect(find.text('代码'), findsOneWidget);
    expect(find.text('还有 2 行 · 展开'), findsOneWidget);
    expect(find.textContaining('line14'), findsNothing);
    await tester.tap(find.text('还有 2 行 · 展开'));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.textContaining('line14'), findsOneWidget);
  });
  testWidgets('content presentation fits phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final palette = themes[AppThemeId.midnightGold]!;
    final message = ChatMessage(
      role: 'assistant',
      content:
          '## 小标题\n正文。\n> 引用内容。\n```dart\nvoid main() => print("hi");\n```',
      fileUrl: 'https://example.com/note.pdf',
      fileName: '很长但应该正常收住的文件名称.pdf',
      fileType: 'doc',
      fileSize: 8192,
      ocrText: '辅助识别文字',
    );

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      for (final theme in <ThemeData>[palette.light, palette.dark]) {
        await pumpBubble(tester, message, theme: theme);
        expect(
          tester.takeException(),
          isNull,
          reason: '$width ${theme.brightness}',
        );
      }
    }
  });
}
