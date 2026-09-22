import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/gen_image_config_page.dart';
import 'package:continuum_chat/pages/ocr_config_page.dart';
import 'package:continuum_chat/pages/stt_config_page.dart';
import 'package:continuum_chat/services/media_config_api.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
  });

  test('load surfaces public cache first, then masked server state', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'media_config_cache_v1',
      '{"features":{"ocr":{"api_url":"https://cache.example/ocr",'
          '"model":"cache-model","key_configured":false,"configured":false}}}',
    );
    final server = _MediaServer();
    final seen = <MediaConfigSnapshot>[];

    final result = await HttpOverrides.runZoned(
      () => MediaConfigApi().load(onCache: seen.add),
      createHttpClient: (_) => server.client,
    );

    expect(seen.single.ocr.apiUrl, 'https://cache.example/ocr');
    expect(result.ocr.apiUrl, 'https://ocr.example/run');
    expect(result.ocr.keyConfigured, isTrue);
    expect(server.client.requests.single.uri.path, '/media-config');
  });

  test(
    'save keeps an omitted key, explicitly clears it, and preserves size',
    () async {
      final server = _MediaServer();
      final api = MediaConfigApi();

      await HttpOverrides.runZoned(() async {
        await api.save(
          MediaFeature.ocr,
          apiUrl: 'https://new.example/ocr',
          model: 'vision-new',
        );
        await api.save(MediaFeature.ocr, apiKey: '', updateApiKey: true);
        final image = await api.save(
          MediaFeature.image,
          apiUrl: 'https://new.example/image',
          model: 'image-new',
          imageSize: '768x768',
        );
        expect(image.image.imageSize, '768x768');
      }, createHttpClient: (_) => server.client);

      final posts = server.client.requests
          .where((request) => request.method == 'POST')
          .toList();
      expect(posts[0].jsonBody, {
        'feature': 'ocr',
        'api_url': 'https://new.example/ocr',
        'model': 'vision-new',
      });
      expect(posts[1].jsonBody, {'feature': 'ocr', 'api_key': ''});
      expect(posts[2].jsonBody['image_size'], '768x768');
    },
  );

  testWidgets(
    'masked key stays empty on save and clear is an explicit action',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      await binding.setSurfaceSize(const Size(375, 900));
      final server = _MediaServer();
      await HttpOverrides.runZoned(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themes[AppThemeId.midnightGold]!.light,
            home: const OcrConfigPage(),
          ),
        );
        await _pumpUntil(
          tester,
          () =>
              _text(tester, const Key('ocr-api-url')) ==
              'https://ocr.example/run',
        );
        await tester.pump();

        expect(_text(tester, const Key('ocr-api-key')), isEmpty);
        final keyField = tester.widget<TextField>(
          find.byKey(const Key('ocr-api-key')),
        );
        expect(keyField.decoration!.hintText, contains('已在服务器保存'));
        await tester.enterText(
          find.byKey(const Key('ocr-api-url')),
          'https://edited.example/ocr',
        );
        await tester.drag(find.byType(ListView), const Offset(0, -320));
        await tester.pumpAndSettle();
        expect(find.text('清除已存 Key'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('ocr-model')),
          'edited-model',
        );
        await tester.ensureVisible(find.byKey(const Key('ocr-save')));
        await tester.tap(find.byKey(const Key('ocr-save')));
        await _pumpUntil(tester, () => server.postBodies.isNotEmpty);
        expect(server.postBodies.first, {
          'feature': 'ocr',
          'api_url': 'https://edited.example/ocr',
          'model': 'edited-model',
        });

        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('清除已存 Key'));
        await tester.tap(find.text('清除已存 Key'));
        await _pumpUntil(tester, () => server.postBodies.length == 2);
        expect(server.postBodies.last, {'feature': 'ocr', 'api_key': ''});
      }, createHttpClient: (_) => server.client);
    },
  );

  testWidgets('media pages fit 320/375/414 in light and dark without brands', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;
    final server = _MediaServer();

    await HttpOverrides.runZoned(() async {
      for (final width in <double>[320, 375, 414]) {
        await binding.setSurfaceSize(Size(width, 900));
        for (final theme in [appTheme.light, appTheme.dark]) {
          for (final page in <Widget>[
            const OcrConfigPage(),
            const SttConfigPage(),
            const GenImageConfigPage(),
          ]) {
            await tester.pumpWidget(MaterialApp(theme: theme, home: page));
            await tester.pumpAndSettle();
            expect(find.textContaining('硅基流动'), findsNothing);
            expect(find.textContaining('DashScope'), findsNothing);
            expect(
              tester.takeException(),
              isNull,
              reason: '${page.runtimeType} overflowed at $width',
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          }
        }
      }
    }, createHttpClient: (_) => server.client);
  });
}

String _text(WidgetTester tester, Key key) {
  return tester.widget<TextField>(find.byKey(key)).controller!.text;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 40 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

class _MediaServer {
  _MediaServer() {
    client = FakeHttpClient(_handle);
  }

  late FakeHttpClient client;
  final List<Map<String, dynamic>> postBodies = [];
  final Map<String, dynamic> features = {
    'ocr': {
      'api_url': 'https://ocr.example/run',
      'model': 'vision-model',
      'key_configured': true,
      'configured': true,
    },
    'stt': {
      'api_url': 'https://stt.example/run',
      'model': 'speech-model',
      'key_configured': true,
      'configured': true,
    },
    'image': {
      'api_url': 'https://image.example/run',
      'model': 'image-model',
      'image_size': '1024x1024',
      'key_configured': true,
      'configured': true,
    },
  };

  FakeHttpResponseData _handle(FakeHttpRequestData request) {
    if (request.method == 'GET' && request.uri.path == '/media-config') {
      return FakeHttpResponseData.json({'features': features});
    }
    if (request.method == 'POST' && request.uri.path == '/media-config') {
      final body = request.jsonBody;
      postBodies.add(body);
      final feature = body['feature'] as String;
      final target = features[feature] as Map<String, dynamic>;
      for (final field in ['api_url', 'model', 'image_size']) {
        if (body.containsKey(field)) target[field] = body[field];
      }
      if (body.containsKey('api_key')) {
        target['key_configured'] = (body['api_key'] as String).isNotEmpty;
      }
      target['configured'] =
          target['key_configured'] == true &&
          (target['api_url'] as String).isNotEmpty &&
          (target['model'] as String).isNotEmpty;
      return FakeHttpResponseData.json({
        'ok': true,
        'config': {'features': features},
      });
    }
    return FakeHttpResponseData.json({
      'error': 'unexpected ${request.method} ${request.uri.path}',
    }, statusCode: 404);
  }
}
