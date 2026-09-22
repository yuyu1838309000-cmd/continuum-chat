import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/history_hub_page.dart';
import 'package:continuum_chat/pages/read_only_chat_view_page.dart';
import 'package:continuum_chat/pages/search_page.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:continuum_chat/utils/app_theme.dart';
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

RuntimeHistoryRepository _repository(
  Future<http.Response> Function(http.Request) handler,
) => RuntimeHistoryRepository(
  api: RuntimeHistoryApi(client: MockClient(handler)),
  cache: _MemoryCache(),
);

http.Response _json(Map<String, dynamic> body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _capabilities() => {
  'ok': true,
  'history_projection': {
    'version': 1,
    'canonical_search': true,
    'calendar_ranges': true,
    'trash_retention_days': 7,
  },
  'legacy_history_archive': {'available': false},
};

void main() {
  testWidgets('Hub leads with real current content and recent summaries', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(375, 1000));
    addTearDown(() => binding.setSurfaceSize(null));
    final requestedLimits = <String?>[];
    final repository = _repository((request) async {
      expect(request.url.path, '/runtime/epochs');
      requestedLimits.add(request.url.queryParameters['limit']);
      return _json({
        'ok': true,
        'revision': 9,
        'epochs': [
          {
            'epoch_id': 'recent-9',
            'ordinal': 9,
            'status': 'closed',
            'message_count': 18,
            'preview': '那次关于海边的讨论',
          },
          {
            'epoch_id': 'recent-8',
            'ordinal': 8,
            'status': 'closed',
            'message_count': 6,
            'preview': '一起整理旅行清单',
          },
        ],
        'page': {'has_more': false},
      });
    });
    final messages = [
      ChatMessage(role: 'user', content: '第一句'),
      ChatMessage(role: 'assistant', content: '这是当前对话的真实内容'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.light,
        home: HistoryHubPage(currentMessages: messages, repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    expect(requestedLimits, ['1']);
    expect(find.text('当前对话'), findsOneWidget);
    expect(find.text('2 条消息'), findsOneWidget);
    expect(find.text('这是当前对话的真实内容'), findsOneWidget);
    expect(find.text('那次关于海边的讨论'), findsOneWidget);
    expect(find.text('一起整理旅行清单'), findsNothing);
    expect(
      find.byKey(const ValueKey('history-hub-recent-recent-9')),
      findsOneWidget,
    );
  });

  testWidgets('Hub recent conversation opens that conversation directly', (
    tester,
  ) async {
    final repository = _repository((request) async {
      switch (request.url.path) {
        case '/runtime/epochs':
          return _json({
            'ok': true,
            'revision': 9,
            'epochs': [
              {
                'epoch_id': 'recent-direct',
                'ordinal': 9,
                'status': 'closed',
                'message_count': 1,
                'preview': '直接打开这段历史',
              },
            ],
            'page': {'has_more': false},
          });
        case '/runtime/epochs/recent-direct':
          return _json({
            'ok': true,
            'revision': 9,
            'messages': [
              {
                'role': 'assistant',
                'content': '历史详情正文',
                'created_at': '2026-09-03T08:00:00Z',
                'event_id': 'recent-detail-event',
                'epoch_id': 'recent-direct',
              },
            ],
            'page': {'has_more': false},
          });
        default:
          return _json({
            'error': 'unexpected ${request.url.path}',
          }, status: 404);
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.light,
        home: HistoryHubPage(currentMessages: const [], repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('history-hub-recent-recent-direct')),
    );
    await tester.pumpAndSettle();

    final page = tester.widget<ReadOnlyChatViewPage>(
      find.byType(ReadOnlyChatViewPage),
    );
    expect(page.messages.single.content, '历史详情正文');
  });

  testWidgets('Hub recent-content failure is silent and keeps every entry', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => binding.setSurfaceSize(null));
    final repository = _repository(
      (request) async => throw http.ClientException('offline', request.url),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.light,
        home: HistoryHubPage(currentMessages: const [], repository: repository),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有内容'), findsOneWidget);
    expect(find.text('最近的会话'), findsNothing);
    for (final label in ['会话', '搜索', '日历', '最近删除', '导出当前对话']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('search content precedes restrained author and source metadata', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => binding.setSurfaceSize(null));
    final repository = _repository((request) async {
      if (request.url.path == '/runtime/capabilities') {
        return _json(_capabilities());
      }
      return _json({
        'ok': true,
        'revision': 4,
        'results': [
          {
            'role': 'user',
            'content': '正文里的 needle 是主要内容',
            'created_at': '2026-09-03T08:00:00Z',
            'event_id': 'hierarchy-event',
            'epoch_id': 'closed-epoch',
          },
        ],
        'page': {'has_more': false},
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeManager.instance.currentTheme.dark,
        home: SearchPage(
          currentMessages: const [],
          repository: repository,
          debounceDuration: Duration.zero,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump();
    await tester.pumpAndSettle();
    final content = find.byKey(
      const ValueKey('search-hit-content-hierarchy-event'),
    );
    final meta = find.byKey(const ValueKey('search-hit-meta-hierarchy-event'));
    expect(content, findsOneWidget);
    expect(meta, findsOneWidget);
    expect(tester.getTopLeft(content).dy, lessThan(tester.getTopLeft(meta).dy));
    expect(find.text('我'), findsOneWidget);
    expect(find.text('历史对话'), findsOneWidget);
    final metaText = tester.widget<Text>(meta);
    expect(metaText.style?.fontSize, AppType.timestamp);
    expect(tester.takeException(), isNull);
  });
}
