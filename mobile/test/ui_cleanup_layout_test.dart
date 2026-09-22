import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/archived_chat.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/archives_page.dart';
import 'package:continuum_chat/pages/overview_drawer.dart';
import 'package:continuum_chat/pages/read_only_chat_view_page.dart';
import 'package:continuum_chat/services/history_index_item.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

void main() {
  testWidgets('D1 high-frequency UI fits compact widths', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));

    final archive = ArchivedChat(
      id: 'compact',
      archivedAt: DateTime(2026, 8, 28, 20),
      title: '一段比较长的历史标题用于检查紧凑宽度下是否会溢出',
      messages: [ChatMessage(role: 'user', content: '测试历史正文')],
    );

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: OverviewDrawer(
                onOpenHistory: () {},
                onOpenMemory: () {},
                onOpenAssistant: () {},
                onOpenTogether: () {},
                onOpenAbility: () {},
                onOpenSettings: () {},
                onStartNewChat: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'drawer should fit at ${width.toInt()}px',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArchiveListCard(
              chat: HistoryIndexItem(
                id: archive.id,
                epochId: 'epoch-compact',
                messageCount: archive.messages.length,
                archivedAt: archive.archivedAt,
                legacyArchive: false,
                title: archive.title,
              ),
              title: archive.title,
              meta: '20:00 · 1 条 · 未分类',
              inSelection: false,
              selected: false,
              onTap: () {},
              onLongPress: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'archive card should fit at ${width.toInt()}px',
      );
      expect(find.byIcon(LucideIcons.messages_square), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: ReadOnlyChatViewPage(
            title: '历史片段',
            messages: [
              ChatMessage(
                role: 'assistant',
                content: '这是一段用于检查只读页面紧凑宽度布局的较长正文。',
                parts: [
                  ChatMessagePart(
                    type: ChatMessagePartType.reasoning,
                    round: 1,
                    text: '思考过程',
                  ),
                  ChatMessagePart(
                    type: ChatMessagePartType.tool,
                    tools: [ChatToolCallPart(name: 'search')],
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'read-only view should fit at ${width.toInt()}px',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
