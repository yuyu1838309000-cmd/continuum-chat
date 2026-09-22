import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/read_only_chat_view_page.dart';
import 'package:continuum_chat/pages/search_page.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryCache implements RuntimeHistoryCache {
  final Map<String, Object> values = {};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object value) async {
    values[key] = value;
  }
}

http.Response _json(int status, Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), status);

Map<String, dynamic> _capabilities({bool legacy = false}) => {
  'ok': true,
  'history_projection': {
    'version': 1,
    'canonical_search': true,
    'calendar_ranges': true,
    'trash_retention_days': 7,
  },
  'legacy_history_archive': {
    'available': legacy,
    'cutoff_exclusive': '2026-08-14T00:00:00Z',
  },
};

Map<String, dynamic> _runtimeHit(
  String eventId,
  String content, {
  String epochId = 'epoch-1',
  int? rawEventId,
  String? authoredText,
}) => {
  'role': 'user',
  'content': content,
  'authored_text': ?authoredText,
  'created_at': '2026-09-01T08:00:00Z',
  'event_id': eventId,
  'epoch_id': epochId,
  'raw_event_id': ?rawEventId,
};

Map<String, dynamic> _legacyHit(
  String eventId,
  String content, {
  String groupId = 'legacy-1',
  String bucket = 'windowed',
}) => {
  'role': 'assistant',
  'content': content,
  'created_at': '2026-07-01T08:00:00Z',
  'event_id': eventId,
  'group_id': groupId,
  'group_bucket': bucket,
};

RuntimeHistoryRepository _repository(
  Future<http.Response> Function(http.Request) handler, {
  RuntimeHistoryCache? cache,
}) => RuntimeHistoryRepository(
  api: RuntimeHistoryApi(client: MockClient(handler)),
  cache: cache ?? _MemoryCache(),
);

Future<void> _pumpSearch(
  WidgetTester tester,
  RuntimeHistoryRepository repository, {
  List<ChatMessage> currentMessages = const [],
  int pageSize = 30,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SearchPage(
        currentMessages: currentMessages,
        repository: repository,
        debounceDuration: Duration.zero,
        pageSize: pageSize,
      ),
    ),
  );
}

Future<void> _query(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('canonical pagination carries cursor and revision into legacy', (
    tester,
  ) async {
    final requests = <Uri>[];
    final repository = _repository((request) async {
      requests.add(request.url);
      switch (request.url.path) {
        case '/runtime/history/search':
          final cursor = request.url.queryParameters['cursor'];
          if (cursor == null) {
            return _json(200, {
              'ok': true,
              'revision': 7,
              'results': [_runtimeHit('runtime-1', 'needle runtime one')],
              'page': {'has_more': true, 'next_cursor': 'runtime-next'},
            });
          }
          expect(cursor, 'runtime-next');
          return _json(200, {
            'ok': true,
            'revision': 7,
            'results': [_runtimeHit('runtime-2', 'needle runtime two')],
            'page': {'has_more': false},
          });
        case '/runtime/capabilities':
          return _json(200, _capabilities(legacy: true));
        case '/runtime/legacy-history/search':
          expect(request.url.queryParameters['cursor'], isNull);
          return _json(200, {
            'ok': true,
            'results': [_legacyHit('legacy-event', 'needle legacy')],
            'page': {'has_more': false},
          });
        default:
          return _json(404, {'error': 'unexpected ${request.url.path}'});
      }
    });
    await _pumpSearch(tester, repository, pageSize: 1);

    await _query(tester, 'needle');
    expect(find.text('needle runtime one'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('needle runtime two'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('needle legacy'), findsOneWidget);
    expect(
      requests.where((uri) => uri.path == '/runtime/history/search').length,
      2,
    );
  });

  testWidgets('late result from an old query cannot replace the new query', (
    tester,
  ) async {
    final oldResponse = Completer<http.Response>();
    final repository = _repository((request) async {
      if (request.url.path == '/runtime/capabilities') {
        return _json(200, _capabilities());
      }
      final query = request.url.queryParameters['q'];
      if (query == 'old') return oldResponse.future;
      return _json(200, {
        'ok': true,
        'revision': 3,
        'results': [_runtimeHit('new-event', 'new result')],
        'page': {'has_more': false},
      });
    });
    await _pumpSearch(tester, repository);

    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('new result'), findsOneWidget);

    oldResponse.complete(
      _json(200, {
        'ok': true,
        'revision': 3,
        'results': [_runtimeHit('old-event', 'old result')],
        'page': {'has_more': false},
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('new result'), findsOneWidget);
    expect(find.text('old result'), findsNothing);
  });

  testWidgets('active Runtime hit returns the exact eventId index', (
    tester,
  ) async {
    final current = [
      ChatMessage(
        role: 'user',
        content: 'same raw id',
        eventId: 'other-event',
        rawEventId: 99,
      ),
      ChatMessage(
        role: 'assistant',
        content: 'target',
        eventId: 'target-event',
        rawEventId: 1,
      ),
    ];
    final repository = _repository((request) async {
      if (request.url.path == '/runtime/capabilities') {
        return _json(200, _capabilities());
      }
      return _json(200, {
        'ok': true,
        'revision': 4,
        'results': [_runtimeHit('target-event', 'target', rawEventId: 99)],
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
                  builder: (_) => SearchPage(
                    currentMessages: current,
                    repository: repository,
                    debounceDuration: Duration.zero,
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
    await _query(tester, 'target');
    await tester.tap(find.byKey(const ValueKey('search-hit-target-event')));
    await tester.pumpAndSettle();

    expect(result, 1);
  });

  testWidgets('closed Runtime hit opens the fully paged canonical epoch', (
    tester,
  ) async {
    final detailCursors = <String?>[];
    final repository = _repository((request) async {
      switch (request.url.path) {
        case '/runtime/history/search':
          return _json(200, {
            'ok': true,
            'revision': 8,
            'results': [
              _runtimeHit('target-event', 'target', epochId: 'closed-epoch'),
            ],
            'page': {'has_more': false},
          });
        case '/runtime/capabilities':
          return _json(200, _capabilities());
        case '/runtime/epochs/closed-epoch':
          final cursor = request.url.queryParameters['after_seq'];
          detailCursors.add(cursor);
          if (cursor == '0') {
            return _json(200, {
              'ok': true,
              'revision': 8,
              'messages': [_runtimeHit('first-event', 'first')],
              'page': {'has_more': true, 'next_after_seq': 1},
            });
          }
          return _json(200, {
            'ok': true,
            'revision': 8,
            'messages': [
              _runtimeHit('target-event', 'target', epochId: 'closed-epoch'),
            ],
            'page': {'has_more': false},
          });
        default:
          return _json(404, {'error': 'unexpected ${request.url.path}'});
      }
    });
    await _pumpSearch(tester, repository);
    await _query(tester, 'target');
    await tester.tap(find.byKey(const ValueKey('search-hit-target-event')));
    await tester.pumpAndSettle();

    final page = tester.widget<ReadOnlyChatViewPage>(
      find.byType(ReadOnlyChatViewPage),
    );
    expect(page.messages.map((message) => message.content), [
      'first',
      'target',
    ]);
    expect(page.focusEventId, 'target-event');
    expect(detailCursors, ['0', '1']);
  });

  testWidgets('windowed legacy hit opens its full archived group', (
    tester,
  ) async {
    var detailCalls = 0;
    final repository = _repository((request) async {
      switch (request.url.path) {
        case '/runtime/history/search':
          return _json(200, {
            'ok': true,
            'revision': 1,
            'results': const [],
            'page': {'has_more': false},
          });
        case '/runtime/capabilities':
          return _json(200, _capabilities(legacy: true));
        case '/runtime/legacy-history/search':
          return _json(200, {
            'ok': true,
            'results': [_legacyHit('legacy-target', 'legacy target')],
            'page': {'has_more': false},
          });
        case '/runtime/legacy-history/groups/legacy-1':
          detailCalls++;
          return _json(200, {
            'ok': true,
            'messages': [
              _legacyHit('legacy-first', 'legacy first'),
              _legacyHit('legacy-target', 'legacy target'),
            ],
            'page': {'has_more': false},
          });
        default:
          return _json(404, {'error': 'unexpected ${request.url.path}'});
      }
    });
    await _pumpSearch(tester, repository);
    await _query(tester, 'legacy target');
    await tester.tap(find.byKey(const ValueKey('search-hit-legacy-target')));
    await tester.pumpAndSettle();

    final page = tester.widget<ReadOnlyChatViewPage>(
      find.byType(ReadOnlyChatViewPage),
    );
    expect(page.messages, hasLength(2));
    expect(page.focusEventId, 'legacy-target');
    expect(detailCalls, 1);
  });

  testWidgets('supplemental legacy hit uses a single-message safe view', (
    tester,
  ) async {
    var detailCalls = 0;
    final repository = _repository((request) async {
      switch (request.url.path) {
        case '/runtime/history/search':
          return _json(200, {
            'ok': true,
            'revision': 1,
            'results': const [],
            'page': {'has_more': false},
          });
        case '/runtime/capabilities':
          return _json(200, _capabilities(legacy: true));
        case '/runtime/legacy-history/search':
          return _json(200, {
            'ok': true,
            'results': [
              _legacyHit(
                'supplemental-event',
                'orphan message',
                bucket: 'supplemental',
              ),
            ],
            'page': {'has_more': false},
          });
        case '/runtime/legacy-history/groups/legacy-1':
          detailCalls++;
          return _json(500, {'error': 'must not be called'});
        default:
          return _json(404, {'error': 'unexpected ${request.url.path}'});
      }
    });
    await _pumpSearch(tester, repository);
    await _query(tester, 'orphan');
    expect(find.text('旧历史补充'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('search-hit-supplemental-event')),
    );
    await tester.pumpAndSettle();

    final page = tester.widget<ReadOnlyChatViewPage>(
      find.byType(ReadOnlyChatViewPage),
    );
    expect(page.title, '旧历史补充记录');
    expect(page.messages.single.content, 'orphan message');
    expect(detailCalls, 0);
  });

  testWidgets('attachment-only match labels it without exposing hidden text', (
    tester,
  ) async {
    final repository = _repository((request) async {
      if (request.url.path == '/runtime/capabilities') {
        return _json(200, _capabilities());
      }
      return _json(200, {
        'ok': true,
        'revision': 2,
        'results': [
          _runtimeHit(
            'attachment-event',
            'caption\nhidden needle extraction',
            authoredText: 'caption',
          ),
        ],
        'page': {'has_more': false},
      });
    });
    await _pumpSearch(tester, repository);
    await _query(tester, 'Needle');

    expect(find.text('附件内容命中'), findsOneWidget);
    expect(find.text('caption'), findsOneWidget);
    expect(find.textContaining('hidden needle extraction'), findsNothing);
  });

  testWidgets('transport fallback is explicitly shown as offline cache', (
    tester,
  ) async {
    final cache = _MemoryCache();
    final online = _repository((request) async {
      if (request.url.path == '/runtime/capabilities') {
        return _json(200, _capabilities());
      }
      return _json(200, {
        'ok': true,
        'revision': 5,
        'results': [_runtimeHit('cached-event', 'cached needle')],
        'page': {'has_more': false},
      });
    }, cache: cache);
    await online.search('needle');
    final offline = _repository(
      (request) async => throw http.ClientException('offline', request.url),
      cache: cache,
    );
    await _pumpSearch(tester, offline);
    await _query(tester, 'needle');

    expect(find.text('cached needle'), findsOneWidget);
    expect(find.text('当前显示离线缓存结果'), findsOneWidget);
  });

  testWidgets(
    'HTTP failure stays an error and pagination retry keeps results',
    (tester) async {
      var nextAttempts = 0;
      final repository = _repository((request) async {
        if (request.url.path == '/runtime/capabilities') {
          return _json(200, _capabilities());
        }
        final query = request.url.queryParameters['q'];
        if (query == 'http') return _json(500, {'error': 'HTTP is not empty'});
        final cursor = request.url.queryParameters['cursor'];
        if (cursor == null) {
          return _json(200, {
            'ok': true,
            'revision': 11,
            'results': [_runtimeHit('kept-event', 'kept result')],
            'page': {'has_more': true, 'next_cursor': 'next'},
          });
        }
        nextAttempts++;
        if (nextAttempts == 1) {
          return _json(500, {'error': 'temporary page error'});
        }
        return _json(200, {
          'ok': true,
          'revision': 11,
          'results': [_runtimeHit('next-event', 'next result')],
          'page': {'has_more': false},
        });
      });
      await _pumpSearch(tester, repository);

      await _query(tester, 'http');
      expect(find.text('HTTP is not empty'), findsOneWidget);
      expect(find.text('没有找到相关内容'), findsNothing);

      await _query(tester, 'retry');
      await tester.tap(find.byKey(const ValueKey('search-load-more')));
      await tester.pumpAndSettle();
      expect(find.text('kept result'), findsOneWidget);
      expect(find.textContaining('temporary page error'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-retry')));
      await tester.pumpAndSettle();
      expect(find.text('kept result'), findsOneWidget);
      expect(find.text('next result'), findsOneWidget);
      expect(nextAttempts, 2);
    },
  );
}
