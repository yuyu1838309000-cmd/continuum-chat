import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';

/// assistant 消息按自然段拆气泡（v0.2.160）：
/// 一段一气泡、空行不出气泡、标题/引用跟随段落、代码块整块。
void main() {
  Future<ThemeData> pumpBubble(WidgetTester tester, String content) async {
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
    await tester.pumpAndSettle();
    return Theme.of(tester.element(find.byType(MessageBubble)));
  }

  /// 数出正文气泡（assistant 气泡底色 = primaryContainer）。
  int countTextBubbles(WidgetTester tester, Color bubbleColor) {
    return tester.widgetList<Container>(find.byType(Container)).where((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.color == bubbleColor;
    }).length;
  }

  testWidgets('普通文本一行一气泡，空行不产生气泡', (tester) async {
    final theme = await pumpBubble(
      tester,
      '好。\n这条是单独的一条。\n然后这是第二条。\n\n最后一段。\n就这三段，没了。',
    );
    expect(
      countTextBubbles(tester, theme.colorScheme.primaryContainer),
      5,
      reason: '单换行分段应每段一气泡，空行不应产生空白气泡',
    );
  });

  testWidgets('标题跟随所在段落，不单独成气泡', (tester) async {
    final theme = await pumpBubble(tester, '## 标题\n\n这是正文内容');
    expect(
      countTextBubbles(tester, theme.colorScheme.primaryContainer),
      1,
      reason: '标题应并入后面的正文段落',
    );
  });

  testWidgets('引用块跟随前面段落，不单独成气泡', (tester) async {
    final theme = await pumpBubble(
      tester,
      '修正措辞：\n\n> 工具用完别戛然而止。\n\n这样连续调用不受影响。',
    );
    expect(
      countTextBubbles(tester, theme.colorScheme.primaryContainer),
      2,
      reason: '引用块应并入前面段落（修正措辞：+引用 / 后续段落）',
    );
  });

  testWidgets('围栏代码块整块一个气泡', (tester) async {
    final theme = await pumpBubble(
      tester,
      '看这段：\n```dart\nvoid main() {\n  print("hi");\n}\n```\n完。',
    );
    expect(
      countTextBubbles(tester, theme.colorScheme.primaryContainer),
      2,
      reason: '代码块外的两段普通文本各一气泡',
    );
    expect(
      find.textContaining('void main()'),
      findsOneWidget,
      reason: '代码块整块渲染保留',
    );
  });

  testWidgets('assistant markdown 文本显示真实 HTML 实体字符', (tester) async {
    await pumpBubble(tester, '我那是说&quot;应你&quot;的应。');

    expect(find.textContaining('"应你"'), findsOneWidget);
    expect(find.textContaining('&quot;'), findsNothing);
  });
}
