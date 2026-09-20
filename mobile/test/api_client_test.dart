import 'package:continuum_chat/services/api_client.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('chat parses multi-line SSE data events', () async {
    final httpClient = MockClient(
      (_) async => http.Response(
        'data: {"type":"text",\n'
        'data: "data":"hello"}\n\n'
        'data: {"type":"done","message":{}}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final client = ApiClient(const ServerConfig(), httpClient: httpClient);

    final events = await client.chat('hello').toList();

    expect(events.map((event) => event.type), ['text', 'done']);
    expect(events.first.data, 'hello');
    client.close();
  });

  test('chat surfaces server error events', () async {
    final httpClient = MockClient(
      (_) async => http.Response(
        'data: {"type":"error","error":"provider unavailable"}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final client = ApiClient(const ServerConfig(), httpClient: httpClient);

    await expectLater(
      client.chat('hello').toList(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'provider unavailable',
        ),
      ),
    );
    client.close();
  });
}
