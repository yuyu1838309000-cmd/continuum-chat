import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';
import 'package:continuum_chat/models/message.dart';

void main() {
  testWidgets('code block highlight colors', (tester) async {
    final content =
        '看看这段代码：\n```dart\nFuture<void> main() {\n  final x = 42;\n  print("hi");\n}\n```\n完';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              message: ChatMessage(role: 'assistant', content: content),
              isMe: false,
            ),
          ),
        ),
      ),
    );
    // 找所有 Text/SelectableText 里的 span，检查有没有非默认颜色
    final finder = find.byType(SelectableText);
    final widgets = tester.widgetList<SelectableText>(finder);
    var colorCount = 0;
    for (final w in widgets) {
      final span = w.textSpan;
      void walk(InlineSpan? s) {
        if (s == null) return;
        if (s is TextSpan) {
          final c = s.style?.color;
          if (c != null && c != const Color(0xFFE6E6E6)) {
            colorCount++;
            debugPrint('COLORED: [${s.text}] -> $c');
          }
          for (final child in s.children ?? const []) {
            walk(child);
          }
        }
      }

      walk(span);
    }
    debugPrint('total colored spans: $colorCount');
    expect(colorCount, greaterThan(0), reason: '代码块应该有彩色高亮');
  });
}
