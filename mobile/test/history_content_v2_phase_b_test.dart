import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/archives_page.dart';
import 'package:continuum_chat/pages/day_page.dart';
import 'package:continuum_chat/pages/history_trash_page.dart';
import 'package:continuum_chat/pages/read_only_chat_view_page.dart';
import 'package:continuum_chat/services/history_index_item.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_models.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _PhaseBHistoryRepository extends RuntimeHistoryRepository {
  _PhaseBHistoryRepository({
    this.archives = const [],
    this.foldersSnapshot = const HistoryFolderSnapshot(
      items: [],
      fromCache: false,
    ),
    this.daySnapshot = const HistoryDaySnapshot(messages: [], fromCache: false),
    this.trashSnapshot = const HistoryTrashSnapshot(
      items: [],
      fromCache: false,
    ),
  }) : super(
         api: RuntimeHistoryApi(
           client: MockClient((_) async => http.Response('{}', 500)),
         ),
       );

  final List<HistoryIndexItem> archives;
  final HistoryFolderSnapshot foldersSnapshot;
  final HistoryDaySnapshot daySnapshot;
  final HistoryTrashSnapshot trashSnapshot;

  @override
  Future<List<HistoryIndexItem>> historyIndex() async => archives;

  @override
  Future<HistoryFolderSnapshot> folders({int? expectedRevision}) async =>
      foldersSnapshot;

  @override
  Future<HistoryDaySnapshot> completeDayMessages({
    required DateTime start,
    required DateTime end,
    int pageSize = 200,
  }) async => daySnapshot;

  @override
  Future<HistoryTrashSnapshot> completeTrash({int pageSize = 50}) async =>
      trashSnapshot;
}

HistoryIndexItem _archiveItem() => HistoryIndexItem(
  id: 'runtime:phase-b',
  epochId: 'phase-b',
  messageCount: 12,
  archivedAt: DateTime(2026, 9, 3, 10, 15),
  legacyArchive: false,
  title: '管理标题',
  preview: '从海边回来后，我们继续聊了那封信。',
  folderId: 'travel',
);

List<ChatMessage> _dayMessages() => [
  ChatMessage(role: 'user', content: '当天较早的内容'),
  ChatMessage(role: 'assistant', content: '这是当天最后一段真实聊天内容'),
  ChatMessage(role: 'activity', content: '处理过 · 搜索'),
];

HistoryConversationSummary _trashItem() => const HistoryConversationSummary(
  epochId: 'trash-phase-b',
  ordinal: 4,
  status: 'trashed',
  messageCount: 7,
  title: '管理标题',
  preview: '还记得我们一起整理的秋天清单吗？',
);

void main() {
  testWidgets('Archives keeps real preview above restrained metadata', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => binding.setSurfaceSize(null));
    final repository = _PhaseBHistoryRepository(
      archives: [_archiveItem()],
      foldersSnapshot: const HistoryFolderSnapshot(
        items: [HistoryFolder(folderId: 'travel', name: '旅行')],
        fromCache: false,
      ),
    );
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.dark,
        home: ArchivesPage(repository: repository, prepareHistory: () async {}),
      ),
    );
    await tester.pumpAndSettle();

    final preview = find.byKey(
      const ValueKey('archive-preview-runtime:phase-b'),
    );
    final meta = find.byKey(const ValueKey('archive-meta-runtime:phase-b'));
    expect(preview, findsOneWidget);
    expect(meta, findsOneWidget);
    expect(tester.getTopLeft(preview).dy, lessThan(tester.getTopLeft(meta).dy));
    expect(tester.widget<Text>(preview).style?.fontSize, AppType.body);
    expect(tester.widget<Text>(meta).style?.fontSize, AppType.timestamp);
    expect(tester.widget<Text>(meta).data, '10:15 · 12 条 · 旅行');
    expect(find.text('管理标题'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Day leads with a real message preview and opens full history', (
    tester,
  ) async {
    final repository = _PhaseBHistoryRepository(
      daySnapshot: HistoryDaySnapshot(
        messages: _dayMessages(),
        fromCache: false,
      ),
    );
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.light,
        home: DayPage(
          date: DateTime(2026, 9, 3),
          repository: repository,
          timezoneOffsetMinutes: 480,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final label = find.byKey(const ValueKey('day-messages-label'));
    final preview = find.byKey(const ValueKey('day-messages-preview'));
    final count = find.byKey(const ValueKey('day-messages-count'));
    expect(tester.widget<Text>(preview).data, '这是当天最后一段真实聊天内容');
    expect(tester.widget<Text>(count).data, '3 条消息');
    expect(
      tester.getTopLeft(preview).dy,
      greaterThan(tester.getTopLeft(label).dy),
    );
    expect(
      tester.widget<Text>(preview).style?.fontSize,
      greaterThan(tester.widget<Text>(label).style!.fontSize!),
    );

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byType(ReadOnlyChatViewPage), findsOneWidget);
    expect(find.text('当天较早的内容'), findsOneWidget);
  });

  testWidgets('Trash keeps preview primary and restore visually clear', (
    tester,
  ) async {
    final repository = _PhaseBHistoryRepository(
      trashSnapshot: HistoryTrashSnapshot(
        items: [_trashItem()],
        fromCache: false,
      ),
    );
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.dark,
        home: HistoryTrashPage(repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    final preview = find.byKey(const ValueKey('trash-preview-trash-phase-b'));
    final meta = find.byKey(const ValueKey('trash-meta-trash-phase-b'));
    expect(tester.widget<Text>(preview).data, '还记得我们一起整理的秋天清单吗？');
    expect(tester.widget<Text>(meta).data, '7 条消息');
    expect(tester.widget<Text>(preview).style?.fontSize, AppType.body);
    expect(tester.widget<Text>(meta).style?.fontSize, AppType.timestamp);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text('删除的会话会在服务器保留 7 天，期间可以恢复。'), findsOneWidget);
    expect(find.textContaining('删除于'), findsNothing);
    expect(find.text('管理标题'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Phase B history content fits compact widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final repository = _PhaseBHistoryRepository(
      archives: [_archiveItem()],
      foldersSnapshot: const HistoryFolderSnapshot(
        items: [HistoryFolder(folderId: 'travel', name: '旅行')],
        fromCache: false,
      ),
      daySnapshot: HistoryDaySnapshot(
        messages: _dayMessages(),
        fromCache: false,
      ),
      trashSnapshot: HistoryTrashSnapshot(
        items: [_trashItem()],
        fromCache: false,
      ),
    );
    addTearDown(repository.close);
    final appTheme = AppThemeManager.instance.currentTheme;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      for (final theme in [appTheme.light, appTheme.dark]) {
        for (final page in <Widget>[
          ArchivesPage(repository: repository, prepareHistory: () async {}),
          DayPage(
            date: DateTime(2026, 9, 3),
            repository: repository,
            timezoneOffsetMinutes: 480,
          ),
          HistoryTrashPage(repository: repository),
        ]) {
          await tester.pumpWidget(MaterialApp(theme: theme, home: page));
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.runtimeType} should fit at ${width.toInt()}px',
          );
        }
      }
    }
  });
}
