import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/assistant_channel_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Map<String, dynamic> body, {int statusCode = 200}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  test(
    'sessions and complete history use only read-only GET endpoints',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        const configuredToken = String.fromEnvironment(
          'CONTINUUM_SERVER_TOKEN',
        );
        if (configuredToken.isEmpty) {
          expect(request.headers['X-Token'], anyOf(isNull, isEmpty));
        }
        if (request.url.path.endsWith('/sessions')) {
          return _json({
            'ok': true,
            'sessions': [
              {
                'session_id': 'session-1',
                'message_count': 2,
                'created_at': '2026-09-12T13:00:00Z',
                'first_message_at': '2026-09-12T13:00:00Z',
                'last_message_at': '2026-09-12T13:01:00Z',
              },
            ],
          });
        }
        expect(request.url.path, '/assistant-channel/history');
        expect(request.url.queryParameters['session_id'], 'session-1');
        if (!request.url.queryParameters.containsKey('before_id')) {
          return _json({
            'ok': true,
            'messages': [
              {
                'id': 2,
                'session_id': 'session-1',
                'role': 'assistant',
                'speaker': 'assistant',
                'content': '完整回答',
                'created_at': '2026-09-12T13:01:00Z',
              },
            ],
            'has_more': true,
            'next_before_id': 2,
          });
        }
        expect(request.url.queryParameters['before_id'], '2');
        return _json({
          'ok': true,
          'messages': [
            {
              'id': 1,
              'session_id': 'session-1',
              'role': 'chatgpt',
              'speaker': 'chatgpt',
              'content': '完整问题',
              'created_at': '2026-09-12T13:00:00Z',
            },
          ],
          'has_more': false,
          'next_before_id': null,
        });
      });
      final api = AssistantChannelApi(client: client);

      final sessions = await api.fetchSessions();
      final messages = await api.fetchHistory(sessions.single.sessionId);

      expect(sessions.single.messageCount, 2);
      expect(messages.map((message) => message.id), [1, 2]);
      expect(messages.first.content, '完整问题');
      expect(messages.last.content, '完整回答');
      expect(requests, hasLength(3));
      expect(requests.every((request) => request.method == 'GET'), isTrue);
    },
  );

  test(
    'audit decodes bridge revisions, refs, notes, tools and traces',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        return switch (request.url.path) {
          '/assistant-channel/memories' => _json({
            'ok': true,
            'memories': [
              {
                'id': 9,
                'previous_version_id': 8,
                'memory_id': 'bridge-1',
                'topic': '一段留档',
                'summary': '摘要',
                'detail': '完整留档',
                'status': 'unresolved',
                'revision_action': 'revise',
                'created_at': '2026-09-12T13:02:00Z',
                'source_refs': [
                  {
                    'session_id': 'session-1',
                    'message_id': 2,
                    'role': 'assistant',
                    'created_at': '2026-09-12T13:01:00Z',
                  },
                ],
              },
            ],
          }),
          '/assistant-channel/notes' => _json({
            'ok': true,
            'notes': [
              {'id': 4, 'content': 'AI 助手写下的 note'},
            ],
          }),
          '/assistant-channel/tool-events' => _json({
            'ok': true,
            'tool_events': [
              {'id': 5, 'tool': 'recall', 'actor': 'assistant'},
            ],
          }),
          '/assistant-channel/traces' => _json({
            'ok': true,
            'traces': [
              {
                'id': 6,
                'trace_type': 'runtime_auto_recall',
                'surface': 'contact',
                'memory_id': 'bridge-1',
                'version_id': 9,
                'match_reason': 'priority=95',
                'created_at': '2026-09-12T13:03:00Z',
                'source_refs': [],
              },
            ],
          }),
          '/assistant-channel/status' => _json({
            'ok': true,
            'quick_check': 'ok',
            'counts': {'sessions': 1, 'messages': 2, 'bridges': 1},
            'last_successful_backup': {'created_at': '2026-09-12T13:04:00Z'},
          }),
          _ => throw StateError('unexpected ${request.url.path}'),
        };
      });

      final audit = await AssistantChannelApi(client: client).fetchAudit();

      expect(audit.bridges.single.versionId, 9);
      expect(audit.bridges.single.previousVersionId, 8);
      expect(audit.bridges.single.sourceRefs.single.messageId, 2);
      expect(audit.notes.single['content'], 'AI 助手写下的 note');
      expect(audit.toolEvents.single['tool'], 'recall');
      expect(
        audit.traces.single.recallKind,
        AssistantChannelRecallKind.automatic,
      );
      expect(audit.status.counts['messages'], 2);
      expect(paths.toSet(), {
        '/assistant-channel/memories',
        '/assistant-channel/notes',
        '/assistant-channel/tool-events',
        '/assistant-channel/traces',
        '/assistant-channel/status',
      });
    },
  );

  test('non-200 and malformed payloads surface a readable failure', () async {
    final denied = AssistantChannelApi(
      client: MockClient((_) async => _json({'ok': false}, statusCode: 403)),
    );
    final malformed = AssistantChannelApi(
      client: MockClient((_) async => http.Response('not-json', 200)),
    );

    await expectLater(
      denied.fetchSessions(),
      throwsA(
        isA<AssistantChannelException>().having(
          (error) => error.statusCode,
          'statusCode',
          403,
        ),
      ),
    );
    await expectLater(
      malformed.fetchSessions(),
      throwsA(
        isA<AssistantChannelException>().having(
          (error) => error.message,
          'message',
          contains('格式'),
        ),
      ),
    );
  });
}
