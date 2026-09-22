import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/chat_page.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:continuum_chat/widgets/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatStore.cache = [];
  });

  tearDown(() {
    ChatStore.cache = null;
  });

  testWidgets('empty chat and composer fit phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final palette = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 720));
      for (final theme in <ThemeData>[palette.light, palette.dark]) {
        ChatStore.cache = [];
        await tester.pumpWidget(
          MaterialApp(theme: theme, home: const ChatPage()),
        );
        await tester.pump();

        expect(find.text('我在这儿，慢慢说。'), findsOneWidget);
        expect(find.text('说点什么吧'), findsNothing);
        expect(find.byTooltip('展开编辑'), findsOneWidget);
        expect(find.byTooltip('发送'), findsOneWidget);
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

  testWidgets('expanded editor writes through live and only offers collapse', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    await binding.setSurfaceSize(const Size(320, 720));

    await tester.pumpWidget(const MaterialApp(home: ChatPage()));
    await tester.pump();
    await tester.tap(find.byTooltip('展开编辑'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '收起'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存'), findsNothing);

    await tester.enterText(find.byType(TextField).last, '这句话还在编辑');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '收起'));
    await tester.pumpAndSettle();

    final composer = tester.widget<TextField>(find.byType(TextField));
    expect(composer.controller?.text, '这句话还在编辑');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('pending image and file copy reads as message delivery state', (
    tester,
  ) async {
    var imageFailureTaps = 0;
    var fileFailureTaps = 0;

    await _pumpBubble(
      tester,
      ChatMessage(
        role: 'user',
        content: '看看这张',
        imageSendStatus: ImageSendStatus.sending,
      ),
      onImageSendTap: () => imageFailureTaps += 1,
    );
    expect(find.text('正在发送图片…'), findsOneWidget);
    expect(find.textContaining('上传'), findsNothing);
    await tester.tap(find.text('正在发送图片…'));
    expect(imageFailureTaps, 0);

    await _pumpBubble(
      tester,
      ChatMessage(
        role: 'user',
        content: '看看这张',
        imageSendStatus: ImageSendStatus.failed,
      ),
      onImageSendTap: () => imageFailureTaps += 1,
    );
    expect(find.text('图片没发出去，点按重试'), findsOneWidget);
    await tester.tap(find.text('图片没发出去，点按重试'));
    expect(imageFailureTaps, 1);

    await _pumpBubble(
      tester,
      ChatMessage(
        role: 'user',
        content: '[文件]',
        fileName: '旅行计划.pdf',
        fileSize: 2048,
        fileType: 'doc',
        fileSendStatus: FileSendStatus.sending,
      ),
      onFileSendTap: () => fileFailureTaps += 1,
    );
    expect(find.text('正在发送文件…'), findsOneWidget);
    expect(find.textContaining('上传'), findsNothing);
    await tester.tap(find.text('正在发送文件…'));
    expect(fileFailureTaps, 0);

    await _pumpBubble(
      tester,
      ChatMessage(
        role: 'user',
        content: '[文件]',
        fileName: '旅行计划.pdf',
        fileSize: 2048,
        fileType: 'doc',
        fileSendStatus: FileSendStatus.failed,
      ),
      onFileSendTap: () => fileFailureTaps += 1,
    );
    expect(find.text('文件没发出去，点按重试'), findsOneWidget);
    await tester.tap(find.text('文件没发出去，点按重试'));
    expect(fileFailureTaps, 1);
  });

  testWidgets('pending failure actions keep resend and delete visible', (
    tester,
  ) async {
    final failedImage = ChatMessage(
      role: 'user',
      content: '图片',
      imageSendStatus: ImageSendStatus.failed,
    );
    final failedFile = ChatMessage(
      role: 'user',
      content: '[文件]',
      fileName: '记录.txt',
      fileSize: 128,
      fileType: 'doc',
      fileSendStatus: FileSendStatus.failed,
    );
    ChatStore.cache = [failedImage, failedFile];

    await tester.pumpWidget(const MaterialApp(home: ChatPage()));
    await tester.pump();

    await tester.tap(find.text('图片没发出去，点按重试'));
    await tester.pumpAndSettle();
    expect(find.text('重新发送'), findsOneWidget);
    expect(find.text('删除消息'), findsOneWidget);
    await tester.tap(find.text('重新发送'));
    await tester.pumpAndSettle();
    expect(find.text('重新发送'), findsNothing);

    await tester.tap(find.text('图片没发出去，点按重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除消息'));
    await tester.pumpAndSettle();
    expect(find.text('图片没发出去，点按重试'), findsNothing);

    await tester.ensureVisible(find.text('文件没发出去，点按重试'));
    await tester.tap(find.text('文件没发出去，点按重试'));
    await tester.pumpAndSettle();
    expect(find.text('重新发送'), findsOneWidget);
    expect(find.text('删除消息'), findsOneWidget);
    await tester.tap(find.text('删除消息'));
    await tester.pumpAndSettle();
    expect(find.text('文件没发出去，点按重试'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('pending failure states fit phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final palette = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 720));
      for (final theme in <ThemeData>[palette.light, palette.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    MessageBubble(
                      message: ChatMessage(
                        role: 'user',
                        content: '一点配字',
                        imageSendStatus: ImageSendStatus.failed,
                      ),
                      isMe: true,
                      showTimestamp: false,
                      onImageSendTap: () {},
                    ),
                    const SizedBox(height: 12),
                    MessageBubble(
                      message: ChatMessage(
                        role: 'user',
                        content: '[文件]',
                        fileName: '很长但不应该撑破窄屏的文件名.pdf',
                        fileSize: 8192,
                        fileType: 'doc',
                        fileSendStatus: FileSendStatus.failed,
                      ),
                      isMe: true,
                      showTimestamp: false,
                      onFileSendTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: '${theme.brightness.name} ${width.toInt()}px',
        );
      }
    }
  });
}

Future<void> _pumpBubble(
  WidgetTester tester,
  ChatMessage message, {
  VoidCallback? onImageSendTap,
  VoidCallback? onFileSendTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: MessageBubble(
            message: message,
            isMe: true,
            showTimestamp: false,
            onImageSendTap: onImageSendTap,
            onFileSendTap: onFileSendTap,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
