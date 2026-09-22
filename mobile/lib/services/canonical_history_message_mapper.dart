import '../models/message.dart';

class CanonicalHistoryMessageMapper {
  const CanonicalHistoryMessageMapper._();

  static ChatMessage fromRuntime(Map<String, dynamic> row) {
    final parts = _parts(row['parts']);
    final attachments = _mapList(row['attachments']);
    final clientFields = _stringMap(row['client_fields']);
    final imageAttachments = attachments
        .where((item) => item['kind']?.toString() == 'image')
        .toList(growable: false);
    final fileAttachment = attachments.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['kind']?.toString() == 'file',
      orElse: () => null,
    );
    final authoredPresent =
        row.containsKey('authored_text') && row['authored_text'] != null;
    final visibleContent = row['role']?.toString() == 'user' && authoredPresent
        ? row['authored_text'].toString()
        : (row['content'] ?? '').toString();
    final imageUrls = imageAttachments
        .map((item) => item['resource_url']?.toString() ?? '')
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    final reasoningParts = parts
        .where(
          (part) =>
              part.type == ChatMessagePartType.reasoning &&
              part.text.isNotEmpty,
        )
        .toList(growable: false);
    final usage = _stringMap(row['usage']);
    return ChatMessage(
      role: (row['role'] ?? 'assistant').toString(),
      content: visibleContent,
      reasoning: reasoningParts.map((part) => part.text).join('\n'),
      reasonings: reasoningParts
          .map((part) => part.text)
          .toList(growable: false),
      time: _time(row['created_at']),
      rawEventId: _int(row['raw_event_id']),
      eventId: row['event_id']?.toString(),
      clientEventId: row['client_event_id']?.toString(),
      generationId: row['generation_id']?.toString(),
      epochId: row['epoch_id']?.toString(),
      kind: row['kind']?.toString(),
      imageUrl: imageUrls.length == 1 ? imageUrls.first : null,
      imageUrls: imageUrls,
      ocrText: clientFields['ocr_text']?.toString(),
      imageOcrTexts: _stringList(clientFields['image_ocr_texts']),
      fileUrl: fileAttachment?['resource_url']?.toString(),
      fileName: fileAttachment?['name']?.toString(),
      fileSize: _int(fileAttachment?['size']),
      fileType: fileAttachment?['media_type']?.toString(),
      fileExtractedText: clientFields['file_extracted_text']?.toString(),
      parts: parts,
      usage: usage.isEmpty ? null : MessageUsage.fromJson(usage),
    );
  }

  static ChatMessage fromLegacyArchive(Map<String, dynamic> row) {
    return ChatMessage(
      role: (row['role'] ?? 'assistant').toString(),
      content: (row['content'] ?? '').toString(),
      time: _time(row['created_at']),
      rawEventId: _int(row['raw_event_id']),
      eventId: row['event_id']?.toString(),
      kind: 'legacy_archive',
    );
  }

  static List<ChatMessagePart> _parts(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          ChatMessagePart.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
  }

  static List<Map<String, dynamic>> _mapList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          item.map((key, value) => MapEntry(key.toString(), value)),
    ];
  }

  static Map<String, dynamic> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return raw.map((item) => item.toString()).toList(growable: false);
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static DateTime _time(Object? value) {
    return DateTime.tryParse(value?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toLocal();
  }
}
