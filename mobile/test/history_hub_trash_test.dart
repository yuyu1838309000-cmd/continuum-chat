import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/archives_page.dart';
import 'package:continuum_chat/pages/calendar_page.dart';
import 'package:continuum_chat/pages/history_hub_page.dart';
import 'package:continuum_chat/pages/history_trash_page.dart';
import 'package:continuum_chat/pages/search_page.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryCache implements RuntimeHistoryCache {
  final values = <String, Object>{};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object value) async {
    values[key] = value;
  }
}

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _trashPage({
  required int revision,
  required List<Map<String, dynamic>> epochs,
  bool hasMore = false,
  int? nextBeforeOrdinal,
}) => {
  'ok': true,
  'revision': revision,
  'epochs': epochs,
  'page': {'has_more': hasMore, 'next_before_ordinal': ?nextBeforeOrdinal},
};

Map<String, dynamic> _epoch(String id, int ordinal, {String? preview}) => {
  'epoch_id': id,
  'ordinal': ordinal,
  'status': 'trashed',
  'message_count': 2,
  'preview': preview ?? '会话 $ordinal',
};

RuntimeHistoryRepository _repository(
  Future<http.Response> Function(http.Request) handler, {
  RuntimeHistoryCache? cache,
}) => RuntimeHistoryRepository(
  api: RuntimeHistoryApi(client: MockClient(handler)),
  cache: cache ?? _MemoryCache(),
);

void main() {
  group('Runtime trash paging', () {
    test('loads every page under one revision', () async {
      final cursors = <String?>[];
      final repository = _repository((request) async {
        final cursor = request.url.queryParameters['before_ordinal'];
        cursors.add(cursor);
        return cursor == null
            ? _json(
                200,
                _trashPage(
                  revision: 9,
                  epochs: [_epoch('epoch-2', 2)],
                  hasMore: true,
                  nextBeforeOrdinal: 2,
                ),
              )
            : _json(
                200,
                _trashPage(revision: 9, epochs: [_epoch('epoch-1', 1)]),
              );
      });

      final snapshot = await repository.completeTrash(pageSize: 1);

      expect(snapshot.items.map((item) => item.epochId), [
        'epoch-2',
        'epoch-1',
      ]);
      expect(snapshot.revision, 9);
      expect(snapshot.fromCache, isFalse);
      expect(cursors, [null, '2']);
    });

    test('refuses to mix trash pages from different revisions', () async {
      final repository = _repository((request) async {
        final cursor = request.url.queryParameters['before_ordinal'];
        return cursor == null
            ? _json(
                200,
                _trashPage(
                  revision: 9,
                  epochs: [_epoch('epoch-2', 2)],
                  hasMore: true,
                  nextBeforeOrdinal: 2,
                ),
              )
            : _json(
                200,
                _trashPage(revision: 10, epochs: [_epoch('epoch-1', 1)]),
              );
      });

      await expectLater(
        repository.completeTrash(pageSize: 1),
        throwsA(
          isA<RuntimeHistoryException>().having(
            (error) => error.kind,
            'kind',
            'revision',
          ),
        ),
      );
    });

    test('supports empty trash and transport-only cache fallback', () async {
      final empty = _repository(
        (request) async =>
            _json(200, _trashPage(revision: 3, epochs: const [])),
      );
      expect((await empty.completeTrash()).items, isEmpty);

      final cache = _MemoryCache();
      final online = _repository(
        (request) async =>
            _json(200, _trashPage(revision: 4, epochs: [_epoch('cached', 1)])),
        cache: cache,
      );
      await online.completeTrash();
      final offline = _repository(
        (request) async => throw http.ClientException('offline'),
        cache: cache,
      );

      final cached = await offline.completeTrash();
      expect(cached.fromCache, isTrue);
      expect(cached.items.single.epochId, 'cached');
    });

    test(
      'HTTP and invalid JSON failures never masquerade as empty trash',
      () async {
        for (final status in [401, 404, 500]) {
          final repository = _repository(
            (request) async => _json(status, {'error': 'status $status'}),
          );
          await expectLater(
            repository.completeTrash(),
            throwsA(
              isA<RuntimeHistoryException>()
                  .having((error) => error.kind, 'kind', 'http')
                  .having((error) => error.statusCode, 'statusCode', status),
            ),
          );
        }

        final invalidJson = _repository(
          (request) async => http.Response('{bad json', 200),
        );
        await expectLater(
          invalidJson.completeTrash(),
          throwsA(
            isA<RuntimeHistoryException>().having(
              (error) => error.kind,
              'kind',
              'contract',
            ),
          ),
        );
      },
    );
  });

  testWidgets('History Hub exposes five compact-width destinations', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => binding.setSurfaceSize(null));
    final repository = _repository((request) async {
      switch (request.url.path) {
        case '/runtime/capabilities':
          return _json(200, {
            'ok': true,
            'history_projection': {
              'version': 1,
              'canonical_search': true,
              'calendar_ranges': true,
              'trash_retention_days': 7,
            },
            'legacy_history_archive': {'available': false},
          });
        case '/runtime/epochs':
        case '/runtime/epochs/trash':
          return _json(200, _trashPage(revision: 1, epochs: const []));
        case '/runtime/archive-folders':
          return _json(200, {'ok': true, 'revision': 1, 'folders': const []});
        case '/runtime/history/calendar':
          return _json(200, {'ok': true, 'revision': 1, 'days': const []});
        default:
          return _json(404, {'error': 'unexpected ${request.url.path}'});
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryHubPage(currentMessages: const [], repository: repository),
      ),
    );

    for (final label in ['会话', '搜索', '日历', '最近删除', '导出当前对话']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    final destinations = <String, Type>{
      '会话': ArchivesPage,
      '搜索': SearchPage,
      '日历': CalendarPage,
      '最近删除': HistoryTrashPage,
    };
    for (final entry in destinations.entries) {
      await tester.tap(find.text(entry.key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(entry.value), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hub search index is passed back to its caller', (tester) async {
    final messages = [
      ChatMessage(role: 'user', content: 'first', eventId: 'event-1'),
      ChatMessage(role: 'assistant', content: 'target', eventId: 'event-2'),
    ];
    final repository = _repository((request) async {
      if (request.url.path == '/runtime/capabilities') {
        return _json(200, {
          'ok': true,
          'history_projection': {
            'version': 1,
            'canonical_search': true,
            'calendar_ranges': true,
            'trash_retention_days': 7,
          },
          'legacy_history_archive': {'available': false},
        });
      }
      return _json(200, {
        'ok': true,
        'revision': 6,
        'results': [
          {
            'role': 'assistant',
            'content': 'target',
            'created_at': '2026-09-03T08:00:00Z',
            'event_id': 'event-2',
            'epoch_id': 'active',
          },
        ],
        'page': {'has_more': false},
      });
    });
    int? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.push<int>(
                context,
                MaterialPageRoute(
                  builder: (_) => HistoryHubPage(
                    currentMessages: messages,
                    repository: repository,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'target');
    await tester.pump(const Duration(milliseconds: 401));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-hit-event-2')));
    await tester.pumpAndSettle();

    expect(result, 1);
  });

  testWidgets('Hub export uses the current runtime-backed list', (
    tester,
  ) async {
    final messages = [ChatMessage(role: 'user', content: 'current')];
    List<ChatMessage>? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryHubPage(
          currentMessages: messages,
          exportConversation: (context, value) async => exported = value,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('history-hub-export')));
    await tester.pump();

    expect(exported, same(messages));
  });

  testWidgets('Hub refuses to export an empty current conversation', (
    tester,
  ) async {
    var exports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryHubPage(
          currentMessages: const [],
          exportConversation: (context, value) async => exports++,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('history-hub-export')));
    await tester.pump();

    expect(exports, 0);
    expect(find.text('还没有可导出的对话'), findsOneWidget);
  });

  testWidgets('restore success refreshes trash from the server', (
    tester,
  ) async {
    var trashLoads = 0;
    var restores = 0;
    final repository = _repository((request) async {
      if (request.method == 'POST') {
        restores++;
        return _json(200, {'ok': true});
      }
      trashLoads++;
      return _json(
        200,
        _trashPage(
          revision: trashLoads,
          epochs: trashLoads == 1 ? [_epoch('restore-me', 1)] : const [],
        ),
      );
    });
    await tester.pumpWidget(
      MaterialApp(home: HistoryTrashPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('trash-restore-restore-me')));
    await tester.pumpAndSettle();

    expect(restores, 1);
    expect(trashLoads, 2);
    expect(find.text('最近没有删除的会话'), findsOneWidget);
  });

  testWidgets('restore failure keeps the trash item visible', (tester) async {
    var trashLoads = 0;
    final repository = _repository((request) async {
      if (request.method == 'POST') {
        return _json(500, {'error': '恢复被拒绝'});
      }
      trashLoads++;
      return _json(
        200,
        _trashPage(revision: 1, epochs: [_epoch('keep-me', 1)]),
      );
    });
    await tester.pumpWidget(
      MaterialApp(home: HistoryTrashPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('trash-restore-keep-me')));
    await tester.pumpAndSettle();

    expect(trashLoads, 1);
    expect(find.text('会话 1'), findsOneWidget);
    expect(find.text('恢复被拒绝'), findsOneWidget);
  });

  test(
    'Settings export entry is removed and chat keeps only top-bar search',
    () async {
      final settings = await File(
        'lib/pages/settings_page.dart',
      ).readAsString();
      expect(settings, isNot(contains('导出对话')));
      expect(settings, isNot(contains('ChatStore')));
      expect(settings, isNot(contains('ChatExporter')));

      final chat = await File('lib/pages/chat_page.dart').readAsString();
      expect(chat, contains("tooltip: '搜索消息'"));
      expect(chat, isNot(contains("tooltip: '历史日历'")));
    },
  );
}
