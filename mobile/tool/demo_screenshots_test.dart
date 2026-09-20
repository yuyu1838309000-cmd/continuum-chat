import 'dart:convert';

import 'package:continuum_chat/app.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _captureKey = ValueKey('demo-capture-root');

final _messages = [
  {
    'id': 'demo-user-1',
    'conversation_id': 'default',
    'epoch_id': 'demo-epoch',
    'role': 'user',
    'content': 'Suggest a thoughtful sci-fi film for tonight.',
    'reasoning': '',
    'generation_id': null,
    'created_at': '2026-09-20T08:20:00Z',
    'provider_usage': <String, dynamic>{},
    'deleted_at': null,
  },
  {
    'id': 'demo-assistant-1',
    'conversation_id': 'default',
    'epoch_id': 'demo-epoch',
    'role': 'assistant',
    'content':
        'Try Arrival. It is thoughtful, human, and still gives you plenty of science-fiction to chew on after the credits.',
    'reasoning': '',
    'generation_id': 'demo-generation-1',
    'created_at': '2026-09-20T08:20:02Z',
    'provider_usage': {'prompt_tokens': 7, 'completion_tokens': 9},
    'deleted_at': null,
  },
  {
    'id': 'demo-user-2',
    'conversation_id': 'default',
    'epoch_id': 'demo-epoch',
    'role': 'user',
    'content': 'Make a two-hour Python study plan for Saturday.',
    'reasoning': '',
    'generation_id': null,
    'created_at': '2026-09-20T08:24:00Z',
    'provider_usage': <String, dynamic>{},
    'deleted_at': null,
  },
  {
    'id': 'demo-assistant-2',
    'conversation_id': 'default',
    'epoch_id': 'demo-epoch',
    'role': 'assistant',
    'content':
        'Start with 50 minutes of focused practice, take a 10 minute break, then spend the final hour building one tiny project.',
    'reasoning': '',
    'generation_id': 'demo-generation-2',
    'created_at': '2026-09-20T08:24:02Z',
    'provider_usage': {'prompt_tokens': 9, 'completion_tokens': 11},
    'deleted_at': null,
  },
];

final _memoryCards = [
  {
    'id': 'demo-memory-1',
    'title': 'Favorite genres',
    'content':
        'Alex enjoys thoughtful science-fiction films and near-future stories.',
    'tags': ['preference', 'demo'],
    'created_at': '2026-09-20T08:00:00Z',
    'updated_at': '2026-09-20T08:00:00Z',
    'archived_at': null,
    'deleted_at': null,
  },
  {
    'id': 'demo-memory-2',
    'title': 'Weekend learning plan',
    'content':
        'Alex plans to spend Saturday morning practicing Python with small projects.',
    'tags': ['plan', 'python'],
    'created_at': '2026-09-20T08:01:00Z',
    'updated_at': '2026-09-20T08:01:00Z',
    'archived_at': null,
    'deleted_at': null,
  },
  {
    'id': 'demo-memory-3',
    'title': 'Study rhythm',
    'content':
        'Use 50 minutes of focused practice followed by a 10 minute break.',
    'tags': ['productivity', 'demo'],
    'created_at': '2026-09-20T08:02:00Z',
    'updated_at': '2026-09-20T08:02:00Z',
    'archived_at': null,
    'deleted_at': null,
  },
];

http.Client _demoClient() => MockClient((request) async {
  final path = request.url.path;
  if (request.method == 'GET' && path == '/runtime/history/messages') {
    return http.Response(
      jsonEncode({'messages': _messages}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'GET' && path == '/runtime/history/calendar') {
    return http.Response(
      jsonEncode({
        'days': [
          {
            'day': '2026-09-20',
            'message_count': 4,
            'provider_usage_count': 2,
            'input_tokens': 16,
            'output_tokens': 20,
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'GET' && path == '/cards') {
    return http.Response(
      jsonEncode({'cards': _memoryCards}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'GET' && path == '/mcp/tools') {
    return http.Response(
      jsonEncode({
        'tools': [
          {
            'server': 'local-files',
            'name': 'list_demo_files',
            'description': 'List files in the repository-local demo workspace.',
          },
          {
            'server': 'local-files',
            'name': 'read_demo_note',
            'description':
                'Read a text note from the repository-local demo workspace.',
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'GET' && path == '/config/provider') {
    return http.Response(
      jsonEncode({
        'base_url': 'mock://local',
        'model': 'continuum-mock',
        'api_key': '',
        'endpoint': '/chat/completions',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  if (request.method == 'GET' && path == '/config/mcp') {
    return http.Response(
      jsonEncode({
        'servers': {
          'local-files': {
            'enabled': true,
            'transport': 'stdio',
            'command': 'npx',
            'args': [
              '-y',
              '@modelcontextprotocol/server-filesystem',
              './mcp-demo-workspace',
            ],
          },
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  return http.Response(
    jsonEncode({
      'detail': 'Demo route not implemented: ${request.method} $path',
    }),
    404,
    headers: {'content-type': 'application/json'},
  );
});

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 10),
  );
}

void main() {
  testWidgets('capture sanitized portfolio screenshots', (tester) async {
    tester.view.physicalSize = const Size(864, 1920);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureKey,
        child: ContinuumApp(
          initialConfig: const ServerConfig(
            host: '127.0.0.1',
            runtimePort: 18816,
            memoryPort: 18820,
          ),
          httpClient: _demoClient(),
        ),
      ),
    );
    await _settle(tester);

    expect(find.textContaining('Arrival'), findsOneWidget);
    await expectLater(
      find.byKey(_captureKey),
      matchesGoldenFile('../../docs/assets/chat.png'),
    );

    await tester.tap(find.byKey(const ValueKey('nav-history')));
    await _settle(tester);
    expect(find.text('Daily usage'), findsOneWidget);
    await expectLater(
      find.byKey(_captureKey),
      matchesGoldenFile('../../docs/assets/history.png'),
    );

    await tester.tap(find.byKey(const ValueKey('nav-memory')));
    await _settle(tester);
    expect(find.text('Favorite genres'), findsOneWidget);
    await expectLater(
      find.byKey(_captureKey),
      matchesGoldenFile('../../docs/assets/memory.png'),
    );

    await tester.tap(find.byKey(const ValueKey('nav-tools')));
    await _settle(tester);
    expect(find.text('list_demo_files'), findsOneWidget);
    await expectLater(
      find.byKey(_captureKey),
      matchesGoldenFile('../../docs/assets/tools.png'),
    );

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await _settle(tester);
    expect(find.text('Provider'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await _settle(tester);
    await expectLater(
      find.byKey(_captureKey),
      matchesGoldenFile('../../docs/assets/settings.png'),
    );
  });
}
