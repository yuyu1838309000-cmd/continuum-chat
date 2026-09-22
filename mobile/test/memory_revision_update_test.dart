import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/memory_card.dart';
import 'package:continuum_chat/services/memory_api.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:continuum_chat/widgets/memory_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
  });

  test('MemoryCard parses current revision without requiring it', () {
    final current = MemoryCard.fromJson({
      'id': 7,
      'title': '当前卡',
      'content': '正文',
      'current_revision_id': 41,
    });
    final legacy = MemoryCard.fromJson({'id': 8, 'content': '旧响应'});

    expect(current.currentRevisionId, 41);
    expect(legacy.currentRevisionId, isNull);
  });

  test(
    'manual write preserves the existing action=new success contract',
    () async {
      late FakeHttpRequestData captured;
      final client = FakeHttpClient((request) {
        captured = request;
        return FakeHttpResponseData.json({
          'ok': true,
          'action': 'new',
          'card_id': 7,
          'current_revision_id': 41,
        });
      });

      final result = await HttpOverrides.runZoned(
        () => MemoryApi.write(title: '手动标题', content: '手动正文'),
        createHttpClient: (_) => client,
      );

      expect(captured.uri.path, '/write');
      expect(captured.jsonBody, {
        'title': '手动标题',
        'content': '手动正文',
        'source': 'manual',
      });
      expect(result.saved, isTrue);
      expect(result.message, '已记下');
    },
  );

  test(
    'update sends expected revision and parses the advanced revision',
    () async {
      late FakeHttpRequestData captured;
      final client = FakeHttpClient((request) {
        captured = request;
        return FakeHttpResponseData.json({
          'id': 7,
          'title': '更新标题',
          'content': '更新正文',
          'current_revision_id': 42,
        });
      });

      final result = await HttpOverrides.runZoned(
        () => MemoryApi.updateCard(
          7,
          expectedCurrentRevisionId: 41,
          title: '更新标题',
          content: '更新正文',
        ),
        createHttpClient: (_) => client,
      );

      expect(captured.uri.path, '/update');
      expect(captured.jsonBody, {
        'card_id': 7,
        'expected_current_revision_id': 41,
        'title': '更新标题',
        'content': '更新正文',
      });
      expect(result.conflict, isFalse);
      expect(result.card?.currentRevisionId, 42);
    },
  );

  test(
    'update distinguishes a stale revision from an ordinary failure',
    () async {
      final conflict = await HttpOverrides.runZoned(
        () => MemoryApi.updateCard(7, expectedCurrentRevisionId: 40),
        createHttpClient: (_) =>
            FakeHttpClient((_) => const FakeHttpResponseData(statusCode: 409)),
      );
      final failed = await HttpOverrides.runZoned(
        () => MemoryApi.updateCard(7, expectedCurrentRevisionId: 41),
        createHttpClient: (_) =>
            FakeHttpClient((_) => const FakeHttpResponseData(statusCode: 500)),
      );

      expect(conflict.conflict, isTrue);
      expect(conflict.card, isNull);
      expect(failed.conflict, isFalse);
      expect(failed.card, isNull);
    },
  );

  testWidgets('detail edit keeps the draft open when revision conflicts', (
    tester,
  ) async {
    late FakeHttpRequestData updateRequest;
    final client = FakeHttpClient((request) {
      if (request.method == 'GET' && request.uri.path == '/card/7') {
        return FakeHttpResponseData.json({
          'id': 7,
          'title': '详情标题',
          'content': '详情正文',
          'current_revision_id': 41,
          'rings': const [],
        });
      }
      if (request.method == 'POST' && request.uri.path == '/update') {
        updateRequest = request;
        return const FakeHttpResponseData(statusCode: 409);
      }
      return const FakeHttpResponseData(statusCode: 404);
    });

    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MemoryDetailSheet(
              card: MemoryCard(id: 7, title: '列表标题', content: '列表正文'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '用户仍在写的稿子');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => client);

    expect(updateRequest.jsonBody['expected_current_revision_id'], 41);
    expect(find.text('编辑记忆'), findsOneWidget);
    expect(find.text('记忆已变化，请刷新后重试'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).last)
          .controller
          .text,
      '用户仍在写的稿子',
    );
  });

  testWidgets('successful detail edit reloads the current card', (
    tester,
  ) async {
    var detailRequests = 0;
    final client = FakeHttpClient((request) {
      if (request.method == 'GET' && request.uri.path == '/card/7') {
        detailRequests += 1;
        return FakeHttpResponseData.json({
          'id': 7,
          'title': '详情标题',
          'content': detailRequests == 1 ? '旧详情正文' : '重拉后的正文',
          'current_revision_id': detailRequests == 1 ? 41 : 42,
          'rings': const [],
        });
      }
      if (request.method == 'POST' && request.uri.path == '/update') {
        return FakeHttpResponseData.json({
          'id': 7,
          'title': '详情标题',
          'content': '重拉后的正文',
          'current_revision_id': 42,
        });
      }
      return const FakeHttpResponseData(statusCode: 404);
    });

    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MemoryDetailSheet(
              card: MemoryCard(id: 7, title: '列表标题', content: '列表正文'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '重拉后的正文');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => client);

    expect(detailRequests, 2);
    expect(find.text('编辑记忆'), findsNothing);
    expect(find.text('重拉后的正文'), findsOneWidget);
  });
}
