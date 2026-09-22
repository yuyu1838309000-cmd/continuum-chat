import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/chat_page.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('composer fits compact Android gesture widths', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 720));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 720),
              padding: const EdgeInsets.only(bottom: 24),
              viewPadding: const EdgeInsets.only(bottom: 24),
            ),
            child: const ChatPage(),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'composer should not overflow at ${width.toInt()}px',
      );
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(find.byTooltip('展开编辑'), findsOneWidget);
      expect(find.byTooltip('快捷消息'), findsOneWidget);
      expect(find.byTooltip('选图片'), findsOneWidget);
      expect(find.byTooltip('拍照'), findsOneWidget);
      expect(find.byTooltip('发文件'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
    'long chat starts at newest edge and growing composer never overlays list',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      addTearDown(() => ChatStore.cache = null);
      SharedPreferences.setMockInitialValues({});
      ChatStore.cache = [
        for (var i = 0; i < 120; i++)
          ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            content: 'message-$i',
          ),
      ];

      await binding.setSurfaceSize(const Size(375, 720));
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(375, 720),
              padding: EdgeInsets.only(bottom: 24),
              viewPadding: EdgeInsets.only(bottom: 24),
            ),
            child: ChatPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final chatListFinder = find.byType(ListView).first;
      final chatList = tester.widget<ListView>(chatListFinder);
      expect(chatList.reverse, isTrue);
      expect(find.text('message-119'), findsOneWidget);

      final composerField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '跟AI 助手说点什么…',
      );
      expect(composerField, findsOneWidget);

      await tester.enterText(composerField, '第一行\n第二行\n第三行\n第四行\n第五行');
      // Composer size is reported after layout; the next frame applies the
      // matching list reserve. Pump both frames to assert the settled layout.
      await tester.pump();
      await tester.pump();

      final fieldRect = tester.getRect(composerField);
      final newestRect = tester.getRect(find.text('message-119'));
      expect(
        newestRect.bottom,
        lessThanOrEqualTo(fieldRect.top),
        reason: 'newest message must stay visible above a growing composer',
      );
      expect(find.text('message-119'), findsOneWidget);
    },
  );
}
