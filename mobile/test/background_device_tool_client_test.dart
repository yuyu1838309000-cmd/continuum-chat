import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/background_device_tool_client.dart';
import 'package:continuum_chat/services/device_capability_bridge.dart';
import 'package:continuum_chat/services/nudge_api.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nudgeChannel = MethodChannel('nudge');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
    DeviceCapabilityBridge.instance.resetForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nudgeChannel, null);
  });

  test(
    'report failure is not ACKed and retry does not repeat the action',
    () async {
      var physicalCalls = 0;
      var reportCalls = 0;
      var ackCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nudgeChannel, (_) async {
            physicalCalls += 1;
            return '{"success":true,"battery":80}';
          });
      final pending = [
        {
          'id': 'pending-1',
          'type': 'activity',
          'generation_id': 'gen-background',
          'tools': [
            {
              'kind': 'nudge',
              'generation_id': 'gen-background',
              'tool_call_id': 'call-background',
              'tool': NudgeApi.deviceStatus,
              'arguments': <String, dynamic>{},
            },
          ],
        },
      ];
      final httpClient = FakeHttpClient((request) {
        switch (request.uri.path) {
          case '/pending':
            return FakeHttpResponseData(
              statusCode: 200,
              body: jsonEncode(pending),
            );
          case '/tool-result':
            reportCalls += 1;
            if (reportCalls == 1) {
              return const FakeHttpResponseData(statusCode: 503);
            }
            return FakeHttpResponseData.json({
              'ok': true,
              'accepted': [
                {
                  'generation_id': 'gen-background',
                  'tool_call_id': 'call-background',
                },
              ],
            });
          case '/pending/ack':
            ackCalls += 1;
            expect(request.jsonBody['ids'], ['pending-1']);
            return FakeHttpResponseData.json({'ok': true});
          default:
            fail('unexpected request ${request.method} ${request.uri}');
        }
      });
      final client = BackgroundDeviceToolClient();

      await HttpOverrides.runZoned(
        () => client.pollOnce(
          host: '127.0.0.1',
          runtimePort: ServerConfig.runtimePort,
          allowProactive: true,
        ),
        createHttpClient: (_) => httpClient,
      );
      expect(physicalCalls, 1);
      expect(reportCalls, 1);
      expect(ackCalls, 0);

      await HttpOverrides.runZoned(
        () => client.pollOnce(
          host: '127.0.0.1',
          runtimePort: ServerConfig.runtimePort,
          allowProactive: true,
        ),
        createHttpClient: (_) => httpClient,
      );
      expect(physicalCalls, 1);
      expect(reportCalls, 2);
      expect(ackCalls, 1);
    },
  );

  test(
    'non-canonical and policy-disabled items are neither run nor ACKed',
    () async {
      var physicalCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nudgeChannel, (_) async {
            physicalCalls += 1;
            return '{"success":true}';
          });
      final httpClient = FakeHttpClient((request) {
        if (request.uri.path != '/pending') {
          fail('invalid item must not report or ACK');
        }
        return FakeHttpResponseData(
          statusCode: 200,
          body: jsonEncode([
            {
              'id': 'missing-call-id',
              'type': 'activity',
              'generation_id': 'gen-invalid',
              'tools': [
                {
                  'kind': 'nudge',
                  'tool': NudgeApi.ping,
                  'arguments': <String, dynamic>{},
                },
              ],
            },
            {
              'id': 'disabled',
              'type': 'message',
              'generation_id': 'gen-disabled',
              'tools': [
                {
                  'kind': 'nudge',
                  'tool_call_id': 'call-disabled',
                  'tool': NudgeApi.ping,
                  'arguments': <String, dynamic>{},
                },
              ],
            },
          ]),
        );
      });

      await HttpOverrides.runZoned(
        () => BackgroundDeviceToolClient().pollOnce(
          host: '127.0.0.1',
          runtimePort: ServerConfig.runtimePort,
          allowProactive: false,
        ),
        createHttpClient: (_) => httpClient,
      );

      expect(physicalCalls, 0);
      expect(httpClient.requests, hasLength(1));
    },
  );

  test('canonical classifier accepts Termux command in arguments', () {
    final tools = canonicalDeviceToolsFromPendingItem({
      'tools': [
        {
          'kind': 'termux',
          'tool_call_id': 'call-termux',
          'arguments': {'command': 'pwd'},
        },
      ],
    }, generationId: 'gen-termux');

    expect(tools, isNotNull);
    expect(tools!.single['tool_call_id'], 'call-termux');
  });

  test('background worker leaves camera snapshot for foreground UI', () {
    final tools = canonicalDeviceToolsFromPendingItem({
      'tools': [
        {
          'kind': 'nudge',
          'tool_call_id': 'call-camera',
          'tool': NudgeApi.cameraSnapshot,
          'arguments': <String, dynamic>{},
        },
      ],
    }, generationId: 'gen-camera');

    expect(tools, isNull);
  });

  test('visible pending content is never background-ack eligible', () {
    expect(pendingItemHasVisibleContent({'content': '你干嘛呢'}), isTrue);
    expect(
      pendingItemHasVisibleContent({'imageUrl': 'http://x/a.png'}),
      isTrue,
    );
    expect(pendingItemHasVisibleContent({'content': '', 'tools': []}), isFalse);
  });
}
