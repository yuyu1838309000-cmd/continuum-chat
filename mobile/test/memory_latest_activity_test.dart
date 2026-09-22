import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/memory_card.dart';

void main() {
  test('MemoryCard parses latest activity fields additively', () {
    final card = MemoryCard.fromJson({
      'id': 7,
      'title': '旧卡',
      'content': '完整正文',
      'created_at': '2026-08-29 03:00:00',
      'latest_activity_at': '2026-09-05 15:00:39',
      'latest_activity_content': '这次 merge 的新年轮',
      'latest_activity_kind': 'ring',
    });

    expect(card.createdAt, '2026-08-29 03:00:00');
    expect(card.latestActivityAt, '2026-09-05 15:00:39');
    expect(card.latestActivityContent, '这次 merge 的新年轮');
    expect(card.latestActivityKind, 'ring');
  });

  test('MemoryCard remains compatible with old latest response', () {
    final card = MemoryCard.fromJson({
      'id': 8,
      'content': '旧协议正文',
      'created_at': '2026-09-05 04:10:00',
    });

    expect(card.latestActivityAt, isEmpty);
    expect(card.latestActivityContent, isEmpty);
    expect(card.latestActivityKind, isEmpty);
  });
}
