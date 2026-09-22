import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/chat_api.dart';

import 'support/fake_http.dart';

void main() {
  test('fetchSceneMode preserves unknown without configured X-Token', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'GET');
      expect(request.uri.path, '/scene-mode');
      expect(request.headers['x-token'], anyOf(isNull, isEmpty));
      return FakeHttpResponseData.json({'mode': 'unknown'});
    });

    final mode = await HttpOverrides.runZoned(
      ChatApi.fetchSceneMode,
      createHttpClient: (_) => client,
    );

    expect(mode, SceneMode.unknown);
    expect(client.requests, hasLength(1));
  });

  test('fetchSceneMode reads both selectable modes', () async {
    for (final mode in [SceneMode.online, SceneMode.faceToFace]) {
      final client = FakeHttpClient(
        (_) => FakeHttpResponseData.json({'scene_mode': mode.wireValue}),
      );

      final result = await HttpOverrides.runZoned(
        ChatApi.fetchSceneMode,
        createHttpClient: (_) => client,
      );

      expect(result, mode);
    }
  });

  test(
    'saveSceneMode posts selectable modes without configured X-Token',
    () async {
      for (final mode in [SceneMode.online, SceneMode.faceToFace]) {
        late final FakeHttpClient client;
        client = FakeHttpClient((request) {
          expect(request.method, 'POST');
          expect(request.uri.path, '/scene-mode');
          expect(request.headers['x-token'], anyOf(isNull, isEmpty));
          expect(request.headers['content-type'], ['application/json']);
          expect(request.jsonBody, {'mode': mode.wireValue});
          return FakeHttpResponseData.json({'mode': mode.wireValue});
        });

        final result = await HttpOverrides.runZoned(
          () => ChatApi.saveSceneMode(mode),
          createHttpClient: (_) => client,
        );

        expect(result, mode);
        expect(client.requests, hasLength(1));
      }
    },
  );

  test('scene mode request failure returns null', () async {
    final client = FakeHttpClient(
      (_) =>
          FakeHttpResponseData.json({'error': 'unavailable'}, statusCode: 503),
    );

    final fetched = await HttpOverrides.runZoned(
      ChatApi.fetchSceneMode,
      createHttpClient: (_) => client,
    );
    final saved = await HttpOverrides.runZoned(
      () => ChatApi.saveSceneMode(SceneMode.online),
      createHttpClient: (_) => client,
    );

    expect(fetched, isNull);
    expect(saved, isNull);
  });
}
