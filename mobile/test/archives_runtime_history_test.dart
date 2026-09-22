import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/archives_page.dart';
import 'package:continuum_chat/services/history_index_item.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_models.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:continuum_chat/widgets/folder_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryHistoryCache implements RuntimeHistoryCache {
  final Map<String, Object> values = {};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object value) async {
    values[key] = value;
  }
}

class _FakeHistoryRepository extends RuntimeHistoryRepository {
  _FakeHistoryRepository({
    required this.items,
    this.folderItems = const [],
    this.historyFailures = 0,
    this.detailFailures = 0,
    this.detailMessages = const [],
  }) : super(
         api: RuntimeHistoryApi(
           client: MockClient(
             (request) async => http.Response(
               jsonEncode({'ok': false, 'error': 'unexpected request'}),
               500,
             ),
           ),
         ),
       );

  final List<HistoryIndexItem> items;
  final List<HistoryFolder> folderItems;
  int historyFailures;
  int detailFailures;
  final List<ChatMessage> detailMessages;
  int historyCalls = 0;
  final List<String> loadedItemIds = [];

  @override
  Future<List<HistoryIndexItem>> historyIndex() async {
    historyCalls += 1;
    if (historyFailures > 0) {
      historyFailures -= 1;
      throw const RuntimeHistoryException(
        '登录已失效',
        statusCode: 401,
        kind: 'http',
      );
    }
    return items;
  }

  @override
  Future<HistoryFolderSnapshot> folders({int? expectedRevision}) async =>
      HistoryFolderSnapshot(items: folderItems, fromCache: false, revision: 1);

  @override
  Future<List<ChatMessage>> completeConversationMessages(
    HistoryIndexItem item, {
    int pageSize = 200,
  }) async {
    loadedItemIds.add(item.id);
    if (detailFailures > 0) {
      detailFailures -= 1;
      throw const RuntimeHistoryException(
        '详情加载失败',
        statusCode: 500,
        kind: 'http',
      );
    }
    return detailMessages;
  }
}

HistoryIndexItem _runtimeItem({String folderId = 'folder-1'}) =>
    HistoryIndexItem(
      id: 'runtime:epoch-1',
      epochId: 'epoch-1',
      messageCount: 1,
      archivedAt: DateTime(2026, 9, 3, 10),
      legacyArchive: false,
      preview: 'Runtime 正文',
      folderId: folderId,
    );

HistoryIndexItem _legacyItem() => HistoryIndexItem(
  id: 'legacy:legacy-1',
  legacyGroupId: 'legacy-1',
  messageCount: 1,
  archivedAt: DateTime(2026, 7, 1, 10),
  legacyArchive: true,
  preview: '旧窗口正文',
);

void main() {
  testWidgets('401 list failure shows retry and never becomes empty history', (
    tester,
  ) async {
    final repository = _FakeHistoryRepository(
      items: [_runtimeItem()],
      folderItems: const [HistoryFolder(folderId: 'folder-1', name: '工作')],
      historyFailures: 1,
    );
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        home: ArchivesPage(repository: repository, prepareHistory: () async {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录已失效'), findsOneWidget);
    expect(find.text('还没有历史'), findsNothing);
    expect(find.text('重新加载'), findsOneWidget);

    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(repository.historyCalls, 2);
    expect(find.text('Runtime 正文'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('登录已失效'), findsNothing);
  });

  testWidgets('legacy card stays read-only and opens the shared renderer', (
    tester,
  ) async {
    final repository = _FakeHistoryRepository(
      items: [_legacyItem()],
      detailMessages: [
        ChatMessage(
          role: 'assistant',
          content: '旧窗口完整正文',
          time: DateTime(2026, 7, 1, 10),
          kind: 'legacy_archive',
        ),
      ],
    );
    addTearDown(repository.close);
    const cardKey = ValueKey('archive-card-legacy:legacy-1');

    await tester.pumpWidget(
      MaterialApp(
        home: ArchivesPage(repository: repository, prepareHistory: () async {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(LucideIcons.ellipsis), findsNothing);
    await tester.longPress(find.byKey(cardKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsNothing);

    await tester.tap(find.byKey(cardKey));
    await tester.pumpAndSettle();

    expect(repository.loadedItemIds, ['legacy:legacy-1']);
    expect(find.text('旧窗口完整正文'), findsOneWidget);
    expect(find.byType(HistoryChatLoaderPage), findsOneWidget);
  });

  testWidgets('detail failure offers retry and then renders all messages', (
    tester,
  ) async {
    final repository = _FakeHistoryRepository(
      items: const [],
      detailFailures: 1,
      detailMessages: [
        ChatMessage(
          role: 'user',
          content: '重试后的完整正文',
          time: DateTime(2026, 9, 3, 10),
        ),
      ],
    );
    addTearDown(repository.close);

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryChatLoaderPage(
          item: _runtimeItem(),
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('重试后的完整正文'), findsNothing);

    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();

    expect(repository.loadedItemIds, ['runtime:epoch-1', 'runtime:epoch-1']);
    expect(find.text('重试后的完整正文'), findsOneWidget);
  });

  testWidgets('folder picker lists and creates folders through Runtime', (
    tester,
  ) async {
    final seen = <String>[];
    final repository = RuntimeHistoryRepository(
      api: RuntimeHistoryApi(
        client: MockClient((request) async {
          seen.add('${request.method} ${request.url.path}');
          if (request.method == 'GET' &&
              request.url.path == '/runtime/archive-folders') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'revision': 1,
                'folders': [
                  {'folder_id': 'server-1', 'name': '服务器文件夹'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/runtime/archive-folders') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['name'], '新文件夹');
            expect(body['command_id'], startsWith('history-ui-'));
            return http.Response(
              jsonEncode({
                'ok': true,
                'folder': {'folder_id': 'server-2', 'name': '新文件夹'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({'ok': false, 'error': 'unexpected'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
      cache: _MemoryHistoryCache(),
    );
    addTearDown(repository.close);
    ({String? id, String name})? choice;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await showFolderPicker(
                  context,
                  allowCreate: true,
                  repository: repository,
                  prepareHistory: () async {},
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('服务器文件夹'), findsOneWidget);

    await tester.tap(find.text('新建文件夹…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新文件夹');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('新文件夹'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(choice, (id: 'server-2', name: '新文件夹'));
    expect(seen, [
      'GET /runtime/archive-folders',
      'POST /runtime/archive-folders',
    ]);
  });
}
