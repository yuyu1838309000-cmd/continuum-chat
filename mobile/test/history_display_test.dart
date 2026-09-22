import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/archived_chat.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/archives_page.dart';
import 'package:continuum_chat/pages/read_only_chat_view_page.dart';
import 'package:continuum_chat/services/history_index_item.dart';
import 'package:continuum_chat/utils/archive_display.dart';
import 'package:continuum_chat/utils/read_only_chat_entries.dart';
import 'package:continuum_chat/utils/reasoning_pref.dart';
import 'package:continuum_chat/utils/timestamp_pref.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

void main() {
  test('历史列表按归档日期分组，组内保持传入的新旧顺序', () {
    final latest = _archive(
      id: 'latest',
      archivedAt: DateTime(2026, 8, 27, 22),
      messages: [_message('user', '新的正文')],
    );
    final earlierSameDay = _archive(
      id: 'same-day',
      archivedAt: DateTime(2026, 8, 27, 9),
      messages: [_message('user', '同一天更早')],
    );
    final yesterday = _archive(
      id: 'yesterday',
      archivedAt: DateTime(2026, 8, 26, 23),
      messages: [_message('user', '昨天')],
    );

    final groups = groupArchivesByArchivedDate([
      latest,
      earlierSameDay,
      yesterday,
    ]);

    expect(groups.map((group) => group.dateKey), ['2026-08-27', '2026-08-26']);
    expect(groups.first.items.map((archive) => archive.id), [
      'latest',
      'same-day',
    ]);
  });

  test('历史卡片标题优先取首个有效正文，空内容回退落盘标题', () {
    final withParts = _archive(
      id: 'parts',
      title: '会话 08-27 12:00',
      messages: [
        _message('activity', '静默活动不当标题'),
        ChatMessage(
          role: 'assistant',
          content: '',
          parts: [
            ChatMessagePart(
              type: ChatMessagePartType.reasoning,
              text: '只是一段思考',
            ),
            ChatMessagePart(
              type: ChatMessagePartType.tool,
              tools: const [ChatToolCallPart(name: 'search')],
            ),
            ChatMessagePart(type: ChatMessagePartType.text, text: '真正的正文'),
          ],
        ),
      ],
    );
    final empty = _archive(
      id: 'empty',
      title: '会话 08-27 12:01',
      messages: [
        _message('assistant', ' [图片] '),
        ChatMessage(
          role: 'assistant',
          content: '',
          parts: [
            ChatMessagePart(
              type: ChatMessagePartType.reasoning,
              text: '不展示成标题',
            ),
          ],
        ),
      ],
    );
    final longTitle = archiveDisplayTitle(
      _archive(
        id: 'long',
        messages: [_message('user', List.filled(24, '很长的一句正文').join())],
      ),
    );

    expect(archiveDisplayTitle(withParts), '真正的正文');
    expect(archiveDisplayTitle(empty), '会话 08-27 12:01');
    expect(longTitle.endsWith('...'), isTrue);
    expect(
      longTitle.runes.length,
      lessThanOrEqualTo(archiveDisplayTitleMaxCharacters + 3),
    );
  });

  test('历史文件夹筛选只影响展示集合', () {
    final uncategorized = _archive(id: 'u', messages: [_message('user', 'u')]);
    final folderA = _archive(
      id: 'a',
      folderId: 'folder-a',
      messages: [_message('user', 'a')],
    );
    final folderB = _archive(
      id: 'b',
      folderId: 'folder-b',
      messages: [_message('user', 'b')],
    );

    expect(
      filterArchives([uncategorized, folderA, folderB], archiveFilterAll),
      [uncategorized, folderA, folderB],
    );
    expect(
      filterArchives([
        uncategorized,
        folderA,
        folderB,
      ], archiveFilterUncategorized),
      [uncategorized],
    );
    expect(filterArchives([uncategorized, folderA, folderB], 'folder-a'), [
      folderA,
    ]);
  });

  test('多选返回只在页面未退出时清空选择态', () {
    expect(
      shouldExitArchiveSelectionOnBlockedPop(didPop: false, inSelection: true),
      isTrue,
    );
    expect(
      shouldExitArchiveSelectionOnBlockedPop(didPop: true, inSelection: true),
      isFalse,
    );
    expect(
      shouldExitArchiveSelectionOnBlockedPop(didPop: false, inSelection: false),
      isFalse,
    );
  });

  test('只读消息日期分隔不会改变 focus 原消息定位', () {
    final messages = [
      _message('user', '第一天', time: DateTime(2026, 8, 26, 23), rawId: 101),
      _message('assistant', '第二天', time: DateTime(2026, 8, 27), rawId: 102)
        ..eventId = 'event-102',
      _message('user', '同一天', time: DateTime(2026, 8, 27, 1), rawId: 103),
    ];

    final entries = buildReadOnlyChatEntries(messages);
    final focus = resolveReadOnlyFocusMessageIndex(
      messages,
      focusEventId: 'event-102',
      focusRawEventId: 102,
      focusIndex: 0,
    );

    expect(entries.map((entry) => entry.type), [
      ReadOnlyChatEntryType.date,
      ReadOnlyChatEntryType.message,
      ReadOnlyChatEntryType.date,
      ReadOnlyChatEntryType.message,
      ReadOnlyChatEntryType.message,
    ]);
    expect(focus, 1);
    expect(readOnlyEntryIndexForMessageIndex(entries, focus), 3);
    expect(readOnlyDateLabel(messages[1].time), '2026年8月27日 周四');
  });

  test('只读 focus 优先 eventId，并兼容 rawEventId 与 index', () {
    final messages = [
      _message('user', 'index', rawId: 1)..eventId = 'event-index',
      _message('assistant', 'raw', rawId: 2)..eventId = 'event-raw',
      _message('user', 'event', rawId: 3)..eventId = 'event-target',
    ];

    expect(
      resolveReadOnlyFocusMessageIndex(
        messages,
        focusEventId: 'event-target',
        focusRawEventId: 2,
        focusIndex: 0,
      ),
      2,
    );
    expect(resolveReadOnlyFocusMessageIndex(messages, focusRawEventId: 2), 1);
    expect(resolveReadOnlyFocusMessageIndex(messages, focusIndex: 0), 0);
  });

  testWidgets('单条历史卡片长按进入选择，删除入口只在更多菜单里', (tester) async {
    var tapped = false;
    var selected = false;
    var deleted = false;
    final chat = _archive(id: 'card', messages: [_message('user', '卡片正文')]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArchiveListCard(
            chat: HistoryIndexItem(
              id: chat.id,
              epochId: 'epoch-card',
              messageCount: chat.messages.length,
              archivedAt: chat.archivedAt,
              legacyArchive: false,
              title: chat.title,
            ),
            title: '卡片正文',
            meta: '10:00 · 1 条 · 未分类',
            inSelection: false,
            selected: false,
            onTap: () => tapped = true,
            onLongPress: () => selected = true,
            onDelete: () => deleted = true,
          ),
        ),
      ),
    );

    expect(find.byIcon(LucideIcons.trash_2), findsNothing);
    await tester.tap(find.byKey(const ValueKey('archive-card-card')));
    expect(tapped, isTrue);

    await tester.longPress(find.byKey(const ValueKey('archive-card-card')));
    expect(selected, isTrue);

    await tester.tap(find.byIcon(LucideIcons.ellipsis));
    await _pumpUi(tester);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    expect(deleted, isTrue);
  });

  testWidgets('多选操作区显示选中数量并保留移动入口', (tester) async {
    var cancelled = false;
    var moved = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArchiveSelectionActionBar(
            count: 2,
            onCancel: () => cancelled = true,
            onMove: () => moved = true,
          ),
        ),
      ),
    );

    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.text('移动到'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.folder_input));
    expect(moved, isTrue);
    await tester.tap(find.byIcon(LucideIcons.x));
    expect(cancelled, isTrue);
  });

  testWidgets('只读页显示跨日日期标签并按 parts 过程段渲染', (tester) async {
    ReasoningPref.show.value = true;
    TimestampPref.show.value = true;
    addTearDown(() {
      ReasoningPref.show.value = true;
      TimestampPref.show.value = true;
    });

    final messages = [
      _message('user', '第一天', time: DateTime(2026, 8, 26, 23, 50)),
      ChatMessage(
        role: 'assistant',
        content: '',
        time: DateTime(2026, 8, 27, 0, 10),
        parts: [
          ChatMessagePart(
            type: ChatMessagePartType.reasoning,
            round: 1,
            text: '先想一下',
          ),
          ChatMessagePart(
            type: ChatMessagePartType.tool,
            round: 1,
            tools: const [ChatToolCallPart(name: 'search')],
          ),
          ChatMessagePart(type: ChatMessagePartType.text, text: '正文来了'),
        ],
      ),
      _message('activity', '活动灰气泡', time: DateTime(2026, 8, 27, 0, 12)),
      _message(
        'tool_done',
        ChatMessage.toolDoneLabel,
        time: DateTime(2026, 8, 27, 0, 13),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ReadOnlyChatViewPage(title: '历史片段', messages: messages),
      ),
    );
    await tester.pump();

    expect(find.text('2026年8月26日 周三'), findsOneWidget);
    expect(find.text('2026年8月27日 周四'), findsOneWidget);
    expect(find.text('处理过 · 搜索'), findsOneWidget);
    final processInk = find
        .ancestor(of: find.text('处理过 · 搜索'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(processInk).height, greaterThanOrEqualTo(44));
    await tester.tap(find.text('处理过 · 搜索'));
    await _pumpUi(tester);
    expect(find.text('处理好了 · 搜索'), findsOneWidget);
    final toolInk = find
        .ancestor(of: find.text('处理好了 · 搜索'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(toolInk).height, greaterThanOrEqualTo(44));
    expect(find.text('正文来了'), findsOneWidget);
    expect(find.text('活动灰气泡'), findsOneWidget);
    expect(find.text('处理好了'), findsOneWidget);
  });

  testWidgets('只读页保留旧图片和文件消息渲染', (tester) async {
    final messages = [
      ChatMessage(
        role: 'user',
        content: '[图片]',
        time: DateTime(2026, 8, 27, 10),
        imageUrl: 'https://example.com/old.png',
      ),
      ChatMessage(
        role: 'user',
        content: '[文件]',
        time: DateTime(2026, 8, 27, 10, 1),
        fileUrl: 'https://example.com/list.pdf',
        fileName: '旅行清单.pdf',
        fileSize: 1536,
        fileType: 'doc',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ReadOnlyChatViewPage(title: '历史片段', messages: messages),
      ),
    );
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.text('旅行清单.pdf'), findsOneWidget);
    expect(find.text('文档 · 1.5 KB'), findsOneWidget);
    expect(find.text('[图片]'), findsNothing);
    expect(find.text('[文件]'), findsNothing);
  });

  testWidgets('只读页保留 parts 图片渲染', (tester) async {
    final messages = [
      ChatMessage(
        role: 'assistant',
        content: '',
        time: DateTime(2026, 8, 27, 10),
        parts: [
          ChatMessagePart(
            type: ChatMessagePartType.image,
            url: 'https://example.com/part.png',
          ),
          ChatMessagePart(type: ChatMessagePartType.text, text: '图片后说明'),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ReadOnlyChatViewPage(title: '历史片段', messages: messages),
      ),
    );
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.text('图片后说明'), findsOneWidget);
  });

  testWidgets('只读页纯 reasoning 遵循显示思考开关', (tester) async {
    ReasoningPref.show.value = false;
    addTearDown(() => ReasoningPref.show.value = true);

    final messages = [
      ChatMessage(
        role: 'assistant',
        content: '',
        time: DateTime(2026, 8, 27),
        parts: [
          ChatMessagePart(type: ChatMessagePartType.reasoning, text: '隐藏的思考'),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ReadOnlyChatViewPage(title: '历史片段', messages: messages),
      ),
    );
    await tester.pump();

    expect(find.text('我在想'), findsNothing);
    expect(find.textContaining('隐藏的思考'), findsNothing);
  });
}

ArchivedChat _archive({
  required String id,
  DateTime? archivedAt,
  String title = '会话 08-27 10:00',
  List<ChatMessage> messages = const [],
  String? folderId,
  String? folderName,
}) {
  return ArchivedChat(
    id: id,
    archivedAt: archivedAt ?? DateTime(2026, 8, 27, 10),
    title: title,
    messages: messages,
    folderId: folderId,
    folderName: folderName,
  );
}

ChatMessage _message(
  String role,
  String content, {
  DateTime? time,
  int? rawId,
}) {
  return ChatMessage(
    role: role,
    content: content,
    time: time ?? DateTime(2026, 8, 27, 10),
    rawEventId: rawId,
  );
}

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260));
}
