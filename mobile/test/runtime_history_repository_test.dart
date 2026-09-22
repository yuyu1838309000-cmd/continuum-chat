import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/canonical_history_message_mapper.dart';
import 'package:continuum_chat/services/history_index_item.dart';
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

Map<String, dynamic> _capabilities({bool legacy = true}) => {
  'ok': true,
  'history_projection': {
    'version': 1,
    'canonical_search': true,
    'calendar_ranges': true,
    'trash_retention_days': 7,
  },
  'legacy_history_archive': {
    'available': legacy,
    if (legacy) 'cutoff_exclusive': '2026-08-12T20:07:33.786236Z',
  },
};

void main() {
  group('RuntimeHistoryRepository cache and revision', () {
    test(
      'network success caches by server and transport failure falls back',
      () async {
        final cache = _MemoryCache();
        final onlineApi = RuntimeHistoryApi(
          client: MockClient(
            (request) async => _json(200, {
              'ok': true,
              'revision': 7,
              'epochs': [
                {
                  'epoch_id': 'epoch-7',
                  'ordinal': 7,
                  'status': 'closed',
                  'message_count': 2,
                },
              ],
              'page': {'has_more': false},
            }),
          ),
        );
        final online = RuntimeHistoryRepository(api: onlineApi, cache: cache);
        final first = await online.conversations();
        expect(first.fromCache, isFalse);
        expect(first.revision, 7);
        expect(first.items.single.epochId, 'epoch-7');
        expect(cache.values.keys.single, contains('127.0.0.1:8816'));

        var offlineCalls = 0;
        final offlineApi = RuntimeHistoryApi(
          client: MockClient((request) async {
            offlineCalls += 1;
            throw http.ClientException('offline');
          }),
        );
        final offline = RuntimeHistoryRepository(api: offlineApi, cache: cache);
        final fallback = await offline.conversations();
        expect(fallback.fromCache, isTrue);
        expect(fallback.items.single.epochId, 'epoch-7');
        expect(offlineCalls, 2);
      },
    );

    test('HTTP failure never masquerades as offline cache', () async {
      final cache = _MemoryCache()
        ..values['history-cache://127.0.0.1:8816/runtime/epochs?before=&limit=50'] =
            {
              'ok': true,
              'revision': 1,
              'epochs': const [],
              'page': {'has_more': false},
            };
      final api = RuntimeHistoryApi(
        client: MockClient((request) async => _json(500, {'error': 'boom'})),
      );
      final repository = RuntimeHistoryRepository(api: api, cache: cache);
      await expectLater(
        repository.conversations(),
        throwsA(
          isA<RuntimeHistoryException>()
              .having((e) => e.kind, 'kind', 'http')
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('revision mismatch refuses to mix pages', () async {
      final api = RuntimeHistoryApi(
        client: MockClient(
          (request) async => _json(200, {
            'ok': true,
            'revision': 8,
            'epochs': const [],
            'page': {'has_more': false},
          }),
        ),
      );
      final repository = RuntimeHistoryRepository(
        api: api,
        cache: _MemoryCache(),
      );
      await expectLater(
        repository.conversations(expectedRevision: 7),
        throwsA(
          isA<RuntimeHistoryException>().having(
            (e) => e.kind,
            'kind',
            'revision',
          ),
        ),
      );
    });

    test(
      'calendar HTTP and invalid JSON failures never become empty data',
      () async {
        for (final status in [401, 404, 500]) {
          final api = RuntimeHistoryApi(
            client: MockClient((request) async {
              if (request.url.path == '/runtime/capabilities') {
                return _json(200, _capabilities(legacy: false));
              }
              return _json(status, {'error': 'status $status'});
            }),
          );
          final repository = RuntimeHistoryRepository(
            api: api,
            cache: _MemoryCache(),
          );
          await expectLater(
            repository.calendar(
              start: DateTime.parse('2026-09-01T00:00:00Z'),
              end: DateTime.parse('2026-10-01T00:00:00Z'),
              timezoneOffsetMinutes: 0,
            ),
            throwsA(
              isA<RuntimeHistoryException>()
                  .having((error) => error.kind, 'kind', 'http')
                  .having((error) => error.statusCode, 'statusCode', status),
            ),
          );
        }

        final invalidJsonApi = RuntimeHistoryApi(
          client: MockClient((request) async {
            if (request.url.path == '/runtime/capabilities') {
              return _json(200, _capabilities(legacy: false));
            }
            return http.Response('{bad json', 200);
          }),
        );
        final invalidJsonRepository = RuntimeHistoryRepository(
          api: invalidJsonApi,
          cache: _MemoryCache(),
        );
        await expectLater(
          invalidJsonRepository.calendar(
            start: DateTime.parse('2026-09-01T00:00:00Z'),
            end: DateTime.parse('2026-10-01T00:00:00Z'),
            timezoneOffsetMinutes: 0,
          ),
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

  group('CanonicalHistoryMessageMapper', () {
    test(
      'restores visible authored text and structured attachment metadata',
      () {
        final message = CanonicalHistoryMessageMapper.fromRuntime({
          'role': 'user',
          'content': '配字\n隐藏附件正文 needle',
          'authored_text': '配字',
          'created_at': '2026-08-13T00:00:00Z',
          'event_id': 'event-1',
          'epoch_id': 'epoch-1',
          'raw_event_id': 88,
          'parts': [
            {'type': 'reasoning', 'text': '想一下'},
            {'type': 'text', 'text': '配字'},
          ],
          'attachments': [
            {'kind': 'image', 'resource_url': 'https://x/a.jpg'},
            {
              'kind': 'file',
              'resource_url': 'https://x/a.pdf',
              'name': 'a.pdf',
              'size': 123,
              'media_type': 'doc',
            },
          ],
          'client_fields': {
            'ocr_text': '图片字',
            'image_ocr_texts': ['图片字'],
            'file_extracted_text': '文件字',
          },
          'usage': {
            'prompt_tokens': 10,
            'prompt_cache_hit_tokens': 8,
            'prompt_cache_miss_tokens': 2,
            'completion_tokens': 3,
          },
        });
        expect(message.content, '配字');
        expect(message.eventId, 'event-1');
        expect(message.epochId, 'epoch-1');
        expect(message.rawEventId, 88);
        expect(message.reasoning, '想一下');
        expect(message.imageUrl, 'https://x/a.jpg');
        expect(message.ocrText, '图片字');
        expect(message.fileUrl, 'https://x/a.pdf');
        expect(message.fileName, 'a.pdf');
        expect(message.fileSize, 123);
        expect(message.fileExtractedText, '文件字');
        expect(message.usage?.cacheHit, 8);
        expect(message.time.toUtc(), DateTime.parse('2026-08-13T00:00:00Z'));

        final canonicalUsage = CanonicalHistoryMessageMapper.fromRuntime({
          'role': 'assistant',
          'content': 'canonical usage',
          'created_at': '2026-08-13T01:00:00Z',
          'usage': {
            'rounds': const [],
            'totals': {
              'input_tokens': 120,
              'output_tokens': 30,
              'cache_read_input_tokens': 90,
              'cache_creation_input_tokens': 30,
            },
          },
        });
        expect(canonicalUsage.usage?.promptTokens, 120);
        expect(canonicalUsage.usage?.completionTokens, 30);
        expect(canonicalUsage.usage?.cacheHit, 90);
        expect(canonicalUsage.usage?.cacheMiss, 30);
      },
    );
  });

  group('Runtime and legacy history composition', () {
    test(
      'history index exhausts both sources and excludes supplemental streams',
      () async {
        final epochCursors = <String?>[];
        final legacyCursors = <String?>[];
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/runtime/epochs':
                final before = request.url.queryParameters['before_ordinal'];
                epochCursors.add(before);
                return _json(200, {
                  'ok': true,
                  'revision': 12,
                  'epochs': [
                    {
                      'epoch_id': before == null ? 'epoch-3' : 'epoch-2',
                      'ordinal': before == null ? 3 : 2,
                      'status': 'closed',
                      'message_count': 1,
                      'last_message_at': before == null
                          ? '2026-09-03T03:00:00Z'
                          : '2026-09-03T02:00:00Z',
                    },
                  ],
                  'page': {
                    'has_more': before == null,
                    if (before == null) 'next_before_ordinal': 2,
                  },
                });
              case '/runtime/capabilities':
                return _json(200, _capabilities());
              case '/runtime/legacy-history/groups':
                final cursor = request.url.queryParameters['cursor'];
                legacyCursors.add(cursor);
                return _json(200, {
                  'ok': true,
                  'groups': cursor == null
                      ? [
                          {
                            'group_id': 'legacy-window-1',
                            'bucket': 'windowed',
                            'message_count': 2,
                            'first_created_at': '2026-08-01T00:00:00Z',
                            'last_created_at': '2026-08-01T01:00:00Z',
                          },
                          {
                            'group_id': 'supplemental-stream',
                            'bucket': 'supplemental',
                            'message_count': 99,
                            'first_created_at': '2026-07-01T00:00:00Z',
                            'last_created_at': '2026-07-01T01:00:00Z',
                          },
                        ]
                      : [
                          {
                            'group_id': 'legacy-window-2',
                            'bucket': 'windowed',
                            'message_count': 3,
                            'first_created_at': '2026-07-31T00:00:00Z',
                            'last_created_at': '2026-07-31T01:00:00Z',
                          },
                        ],
                  'page': {
                    'has_more': cursor == null,
                    if (cursor == null) 'next_cursor': 'legacy-page-2',
                  },
                });
              default:
                return _json(404, {'error': 'unexpected ${request.url}'});
            }
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );

        final items = await repository.historyIndex();

        expect(epochCursors, [null, '2']);
        expect(legacyCursors, [null, 'legacy-page-2']);
        expect(items.where((item) => !item.legacyArchive), hasLength(2));
        expect(
          items.where((item) => item.legacyArchive).map((item) => item.id),
          containsAll(['legacy:legacy-window-1', 'legacy:legacy-window-2']),
        );
        expect(
          items.any((item) => item.id.contains('supplemental-stream')),
          isFalse,
        );
      },
    );

    test('complete details page by after_seq and after_id', () async {
      final runtimeAfter = <String?>[];
      final legacyAfter = <String?>[];
      final api = RuntimeHistoryApi(
        client: MockClient((request) async {
          if (request.url.path == '/runtime/epochs/epoch-1') {
            final after = request.url.queryParameters['after_seq'];
            runtimeAfter.add(after);
            return _json(200, {
              'ok': true,
              'revision': 6,
              'messages': [
                {
                  'role': 'user',
                  'content': after == '0' ? 'runtime first' : 'runtime last',
                  'created_at': '2026-09-01T00:00:00Z',
                  'epoch_id': 'epoch-1',
                },
              ],
              'page': {
                'has_more': after == '0',
                if (after == '0') 'next_after_seq': 4,
              },
            });
          }
          if (request.url.path == '/runtime/legacy-history/groups/legacy-1') {
            final after = request.url.queryParameters['after_id'];
            legacyAfter.add(after);
            return _json(200, {
              'ok': true,
              'messages': [
                {
                  'role': 'assistant',
                  'content': after == '0' ? 'legacy first' : 'legacy last',
                  'created_at': '2026-07-01T00:00:00Z',
                  'raw_event_id': after == '0' ? 10 : 20,
                },
              ],
              'page': {
                'has_more': after == '0',
                if (after == '0') 'next_after_id': 10,
              },
            });
          }
          return _json(404, {'error': 'unexpected ${request.url}'});
        }),
      );
      final repository = RuntimeHistoryRepository(
        api: api,
        cache: _MemoryCache(),
      );
      final runtime = HistoryIndexItem(
        id: 'runtime:epoch-1',
        epochId: 'epoch-1',
        messageCount: 2,
        archivedAt: DateTime(2026, 9, 1),
        legacyArchive: false,
      );
      final legacy = HistoryIndexItem(
        id: 'legacy:legacy-1',
        legacyGroupId: 'legacy-1',
        messageCount: 2,
        archivedAt: DateTime(2026, 7, 1),
        legacyArchive: true,
      );

      final runtimeMessages = await repository.completeConversationMessages(
        runtime,
        pageSize: 1,
      );
      final legacyMessages = await repository.completeConversationMessages(
        legacy,
        pageSize: 1,
      );

      expect(runtimeAfter, ['0', '4']);
      expect(legacyAfter, ['0', '10']);
      expect(runtimeMessages.map((message) => message.content), [
        'runtime first',
        'runtime last',
      ]);
      expect(legacyMessages.map((message) => message.content), [
        'legacy first',
        'legacy last',
      ]);
      expect(
        legacyMessages.every((message) => message.kind == 'legacy_archive'),
        isTrue,
      );
    });

    test(
      'search exhausts runtime then continues legacy without identity mixing',
      () async {
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/runtime/capabilities':
                return _json(200, _capabilities());
              case '/runtime/history/search':
                return _json(200, {
                  'ok': true,
                  'revision': 9,
                  'results': [
                    {
                      'role': 'user',
                      'content': '配字\n附件里有 needle',
                      'authored_text': '配字',
                      'created_at': '2026-08-20T00:00:00Z',
                      'event_id': 'runtime-event',
                      'epoch_id': 'runtime-epoch',
                    },
                  ],
                  'page': {'has_more': false},
                });
              case '/runtime/legacy-history/search':
                return _json(200, {
                  'ok': true,
                  'results': [
                    {
                      'role': 'assistant',
                      'content': 'old needle',
                      'created_at': '2026-07-20T00:00:00Z',
                      'event_id': 'legacy-event',
                      'group_id': 'legacy-group',
                      'group_bucket': 'windowed',
                      'raw_event_id': 9,
                    },
                  ],
                  'page': {'has_more': false},
                });
              default:
                return _json(404, {'error': 'unexpected ${request.url.path}'});
            }
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );
        final page = await repository.search('needle', limit: 5);
        expect(page.results, hasLength(2));
        expect(page.revision, 9);
        expect(page.phase, 'done');
        expect(page.results.first.legacyArchive, isFalse);
        expect(page.results.first.epochId, 'runtime-epoch');
        expect(page.results.first.attachmentContentMatch, isTrue);
        expect(page.results.last.legacyArchive, isTrue);
        expect(page.results.last.legacyGroupId, 'legacy-group');
      },
    );

    test('legacy capability missing ends search cleanly', () async {
      var legacySearchCalls = 0;
      final api = RuntimeHistoryApi(
        client: MockClient((request) async {
          if (request.url.path == '/runtime/history/search') {
            return _json(200, {
              'ok': true,
              'revision': 3,
              'results': const [],
              'page': {'has_more': false},
            });
          }
          if (request.url.path == '/runtime/capabilities') {
            return _json(200, _capabilities(legacy: false));
          }
          if (request.url.path == '/runtime/legacy-history/search') {
            legacySearchCalls += 1;
          }
          return _json(404, {'error': 'not found'});
        }),
      );
      final repository = RuntimeHistoryRepository(
        api: api,
        cache: _MemoryCache(),
      );
      final page = await repository.search('anything');
      expect(page.phase, 'done');
      expect(page.hasMore, isFalse);
      expect(page.revision, 3);
      expect(legacySearchCalls, 0);
    });

    test(
      'boundary day merges legacy then runtime in real time order',
      () async {
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/runtime/capabilities':
                return _json(200, _capabilities());
              case '/runtime/legacy-history/calendar':
                return _json(200, {
                  'ok': true,
                  'days': [
                    {'date': '2026-08-13', 'message_count': 2},
                  ],
                });
              case '/runtime/history/calendar':
                return _json(200, {
                  'ok': true,
                  'revision': 11,
                  'days': [
                    {'date': '2026-08-13', 'message_count': 3},
                  ],
                });
              case '/runtime/legacy-history/messages':
                return _json(200, {
                  'ok': true,
                  'messages': [
                    {
                      'role': 'user',
                      'content': 'old side',
                      'created_at': '2026-08-12T19:30:00Z',
                      'event_id': 'old-event',
                      'group_id': 'old-group',
                      'raw_event_id': 10,
                    },
                  ],
                  'page': {'has_more': false},
                });
              case '/runtime/history/messages':
                return _json(200, {
                  'ok': true,
                  'revision': 11,
                  'messages': [
                    {
                      'role': 'assistant',
                      'content': 'new side',
                      'created_at': '2026-08-12T21:00:00Z',
                      'event_id': 'new-event',
                      'epoch_id': 'new-epoch',
                    },
                  ],
                  'page': {'has_more': false},
                });
              default:
                return _json(404, {'error': 'unexpected ${request.url.path}'});
            }
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );
        final start = DateTime.parse('2026-08-12T16:00:00Z');
        final end = DateTime.parse('2026-08-13T16:00:00Z');
        final calendar = await repository.calendar(
          start: start,
          end: end,
          timezoneOffsetMinutes: 480,
        );
        expect(calendar.days.single.date, '2026-08-13');
        expect(calendar.days.single.messageCount, 5);
        expect(calendar.revision, 11);

        final messages = await repository.dayMessages(
          start: start,
          end: end,
          limit: 10,
        );
        expect(messages.messages.map((m) => m.content), [
          'old side',
          'new side',
        ]);
        expect(messages.messages.first.kind, 'legacy_archive');
        expect(messages.messages.last.epochId, 'new-epoch');
        expect(messages.revision, 11);
        expect(messages.phase, 'done');
      },
    );

    test(
      'complete day exhausts legacy and runtime pages including supplemental',
      () async {
        final legacyCursors = <String?>[];
        final runtimeCursors = <String?>[];
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/runtime/capabilities':
                return _json(200, _capabilities());
              case '/runtime/legacy-history/messages':
                final cursor = request.url.queryParameters['cursor'];
                legacyCursors.add(cursor);
                return _json(200, {
                  'ok': true,
                  'messages': [
                    {
                      'role': cursor == null ? 'user' : 'assistant',
                      'content': cursor == null
                          ? 'supplemental legacy'
                          : 'windowed legacy',
                      'created_at': cursor == null
                          ? '2026-08-12T18:00:00Z'
                          : '2026-08-12T20:00:00Z',
                      'group_bucket': cursor == null
                          ? 'supplemental'
                          : 'windowed',
                    },
                  ],
                  'page': {
                    'has_more': cursor == null,
                    if (cursor == null) 'next_cursor': 'legacy-2',
                  },
                });
              case '/runtime/history/messages':
                final cursor = request.url.queryParameters['cursor'];
                runtimeCursors.add(cursor);
                return _json(200, {
                  'ok': true,
                  'revision': 21,
                  'messages': [
                    {
                      'role': 'assistant',
                      'content': cursor == null
                          ? 'runtime first'
                          : 'runtime last',
                      'created_at': cursor == null
                          ? '2026-08-12T21:00:00Z'
                          : '2026-08-12T22:00:00Z',
                      'epoch_id': 'epoch-21',
                    },
                  ],
                  'page': {
                    'has_more': cursor == null,
                    if (cursor == null) 'next_cursor': 'runtime-2',
                  },
                });
              default:
                return _json(404, {'error': 'unexpected ${request.url.path}'});
            }
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );

        final snapshot = await repository.completeDayMessages(
          start: DateTime.parse('2026-08-12T16:00:00Z'),
          end: DateTime.parse('2026-08-13T16:00:00Z'),
          pageSize: 1,
        );

        expect(legacyCursors, [null, 'legacy-2']);
        expect(runtimeCursors, [null, 'runtime-2']);
        expect(snapshot.revision, 21);
        expect(snapshot.messages.map((message) => message.content), [
          'supplemental legacy',
          'windowed legacy',
          'runtime first',
          'runtime last',
        ]);
        expect(snapshot.messages.first.kind, 'legacy_archive');
      },
    );

    test(
      'complete day rejects a revision change between runtime pages',
      () async {
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            if (request.url.path == '/runtime/capabilities') {
              return _json(200, _capabilities(legacy: false));
            }
            if (request.url.path == '/runtime/history/messages') {
              final cursor = request.url.queryParameters['cursor'];
              return _json(200, {
                'ok': true,
                'revision': cursor == null ? 5 : 6,
                'messages': const [],
                'page': {
                  'has_more': cursor == null,
                  if (cursor == null) 'next_cursor': 'runtime-2',
                },
              });
            }
            return _json(404, {'error': 'unexpected ${request.url.path}'});
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );

        await expectLater(
          repository.completeDayMessages(
            start: DateTime.parse('2026-09-01T00:00:00Z'),
            end: DateTime.parse('2026-09-02T00:00:00Z'),
            pageSize: 1,
          ),
          throwsA(
            isA<RuntimeHistoryException>().having(
              (error) => error.kind,
              'kind',
              'revision',
            ),
          ),
        );
      },
    );

    test(
      'token usage aggregates only provider usage fields by local day',
      () async {
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            if (request.url.path == '/runtime/capabilities') {
              return _json(200, _capabilities(legacy: false));
            }
            if (request.url.path == '/runtime/history/calendar') {
              return _json(200, {
                'ok': true,
                'revision': 31,
                'days': [
                  {
                    'date': '2026-09-01',
                    'message_count': 2,
                    'provider_usage_count': 1,
                    'input_tokens': 120,
                    'output_tokens': 30,
                  },
                  {
                    'date': '2026-09-02',
                    'message_count': 1,
                    'provider_usage_count': 1,
                    'input_tokens': 80,
                    'output_tokens': 20,
                  },
                  {
                    'date': '2026-09-03',
                    'message_count': 4,
                    'provider_usage_count': 0,
                    'input_tokens': 0,
                    'output_tokens': 0,
                  },
                ],
              });
            }
            return _json(404, {'error': 'unexpected ${request.url.path}'});
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );

        final snapshot = await repository.tokenUsage(
          start: DateTime.parse('2026-09-01T00:00:00Z'),
          end: DateTime.parse('2026-09-04T00:00:00Z'),
          timezoneOffsetMinutes: 480,
        );

        expect(snapshot.days, hasLength(2));
        expect(snapshot.days.first.date, '2026-09-01');
        expect(snapshot.days.first.inputTokens, 120);
        expect(snapshot.days.first.outputTokens, 30);
        expect(snapshot.days.last.date, '2026-09-02');
        expect(snapshot.days.last.inputTokens, 80);
        expect(snapshot.days.last.outputTokens, 20);
      },
    );

    test(
      'token usage chunks long ranges to the calendar summary limit',
      () async {
        final ranges = <(DateTime, DateTime)>[];
        final api = RuntimeHistoryApi(
          client: MockClient((request) async {
            if (request.url.path == '/runtime/capabilities') {
              return _json(200, _capabilities(legacy: false));
            }
            if (request.url.path == '/runtime/history/calendar') {
              final start = DateTime.parse(
                request.url.queryParameters['start']!,
              );
              final end = DateTime.parse(request.url.queryParameters['end']!);
              ranges.add((start, end));
              expect(
                end.difference(start),
                lessThanOrEqualTo(const Duration(days: 62)),
              );
              return _json(200, {
                'ok': true,
                'revision': 32,
                'days': <Object?>[],
              });
            }
            return _json(404, {'error': 'unexpected ${request.url.path}'});
          }),
        );
        final repository = RuntimeHistoryRepository(
          api: api,
          cache: _MemoryCache(),
        );

        final snapshot = await repository.tokenUsage(
          start: DateTime.parse('2026-01-01T00:00:00Z'),
          end: DateTime.parse('2026-05-31T00:00:00Z'),
          timezoneOffsetMinutes: 480,
        );

        expect(snapshot.days, isEmpty);
        expect(ranges, hasLength(3));
        expect(ranges.first.$1, DateTime.parse('2026-01-01T00:00:00Z'));
        expect(ranges.last.$2, DateTime.parse('2026-05-31T00:00:00Z'));
        for (var i = 1; i < ranges.length; i++) {
          expect(ranges[i - 1].$2, ranges[i].$1);
        }
      },
    );
  });
}
