import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_api.dart';

void main() {
  group('Memory raw event API contract', () {
    test('plain user carries raw_event_id and authored_text', () {
      final api = ChatApi.toApiMessageForTesting(
        ChatMessage(role: 'user', content: '原始气泡正文', rawEventId: 101),
      );

      expect(
        api,
        equals({
          'role': 'user',
          'content': '原始气泡正文',
          'authored_text': '原始气泡正文',
          'raw_event_id': 101,
        }),
      );
    });

    test('plain user omits raw_event_id when raw id is null', () {
      final api = ChatApi.toApiMessageForTesting(
        ChatMessage(role: 'user', content: '没有 raw id'),
      );

      expect(api, containsPair('role', 'user'));
      expect(api, containsPair('content', '没有 raw id'));
      expect(api, containsPair('authored_text', '没有 raw id'));
      expect(api, isNot(contains('raw_event_id')));
    });

    test('single image keeps enhanced content and user metadata', () {
      final api = ChatApi.toApiMessageForTesting(
        ChatMessage(
          role: 'user',
          content: '看看这张',
          rawEventId: 202,
          imageUrl: 'https://img.example/single.jpg',
          ocrText: '图片里的文字',
        ),
      );

      expect(api, containsPair('role', 'user'));
      expect(api, containsPair('raw_event_id', 202));
      expect(api, containsPair('authored_text', '看看这张'));
      expect(
        api,
        containsPair(
          'content',
          '看看这张\n[我发了一张图：https://img.example/single.jpg] 图片内容：图片里的文字',
        ),
      );
      expect(api['attachments'], [
        {'kind': 'image', 'resource_url': 'https://img.example/single.jpg'},
      ]);
      expect(api['client_fields'], {'ocr_text': '图片里的文字'});
    });

    test('multi-image keeps enhanced content and user metadata', () {
      final api = ChatApi.toApiMessageForTesting(
        ChatMessage(
          role: 'user',
          content: '这几张一起看',
          rawEventId: 303,
          imageUrls: const [
            'https://img.example/one.jpg',
            'https://img.example/two.jpg',
          ],
          imageOcrTexts: const ['第一张 OCR', ''],
        ),
      );

      expect(api, containsPair('role', 'user'));
      expect(api, containsPair('raw_event_id', 303));
      expect(api, containsPair('authored_text', '这几张一起看'));
      expect(
        api,
        containsPair(
          'content',
          '这几张一起看\n'
              '[我发了 2 张图：]\n'
              '图1：https://img.example/one.jpg\n'
              '图片内容：第一张 OCR\n'
              '图2：https://img.example/two.jpg',
        ),
      );
      expect(api['attachments'], [
        {'kind': 'image', 'resource_url': 'https://img.example/one.jpg'},
        {'kind': 'image', 'resource_url': 'https://img.example/two.jpg'},
      ]);
      expect(api['client_fields'], {
        'image_ocr_texts': ['第一张 OCR', ''],
      });
    });

    test('file keeps enhanced content and user metadata', () {
      final api = ChatApi.toApiMessageForTesting(
        ChatMessage(
          role: 'user',
          content: '帮我读一下',
          rawEventId: 404,
          fileUrl: 'https://file.example/report.pdf',
          fileName: 'report.pdf',
          fileExtractedText: '文件提取正文',
        ),
      );

      expect(api, containsPair('role', 'user'));
      expect(api, containsPair('raw_event_id', 404));
      expect(api, containsPair('authored_text', '帮我读一下'));
      expect(
        api,
        containsPair(
          'content',
          '帮我读一下\n'
              '[我发了一个文件：report.pdf（https://file.example/report.pdf）]\n'
              '文件内容：文件提取正文',
        ),
      );
      expect(api['attachments'], [
        {
          'kind': 'file',
          'resource_url': 'https://file.example/report.pdf',
          'name': 'report.pdf',
        },
      ]);
      expect(api['client_fields'], {'file_extracted_text': '文件提取正文'});
    });

    test('metadata raw ids parse without fabricating null assistant id', () {
      final ids = ChatApi.rawEventIdsFromMetadataForTesting({
        'type': 'metadata',
        'user_raw_event_id': '606',
        'assistant_raw_event_id': null,
      });

      expect(ids.userRawEventId, 606);
      expect(ids.assistantRawEventId, isNull);
    });

    test(
      'assistant preserves raw id when present and omits it when absent',
      () {
        final withId = ChatApi.toApiMessageForTesting(
          ChatMessage(role: 'assistant', content: '回复正文', rawEventId: 505),
        );
        final withoutId = ChatApi.toApiMessageForTesting(
          ChatMessage(role: 'assistant', content: '另一条回复'),
        );

        expect(
          withId,
          equals({'role': 'assistant', 'content': '回复正文', 'raw_event_id': 505}),
        );
        expect(withId, isNot(contains('authored_text')));
        expect(withoutId, containsPair('role', 'assistant'));
        expect(withoutId, containsPair('content', '另一条回复'));
        expect(withoutId, isNot(contains('raw_event_id')));
        expect(withoutId, isNot(contains('authored_text')));
      },
    );

    test('conclusion request_kind stays at body level', () {
      final body = ChatApi.conclusionRequestBodyForTesting([
        ChatMessage(
          role: 'user',
          content: '原始问题',
          rawEventId: 707,
          eventId: 'evt-internal',
          clientEventId: 'client-internal',
          generationId: 'gen-internal',
          epochId: 'epoch-internal',
        ),
      ], searchBlock: '[搜索结果]\n只给模型看的材料');

      expect(body, containsPair('request_kind', 'conclusion'));
      final messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(2));
      for (final message in messages) {
        expect(message, isA<Map<String, dynamic>>());
        expect(
          message as Map<String, dynamic>,
          isNot(contains('request_kind')),
        );
      }
      expect(messages.first, containsPair('raw_event_id', 707));
      for (final key in const [
        'event_id',
        'client_event_id',
        'generation_id',
        'epoch_id',
      ]) {
        expect(messages.first, isNot(contains(key)));
      }
      expect(
        messages.last,
        equals({'role': 'user', 'content': '[搜索结果]\n只给模型看的材料'}),
      );
    });
  });
}
