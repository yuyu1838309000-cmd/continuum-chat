import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

abstract interface class AssistantChannelReader {
  Future<List<AssistantChannelSession>> fetchSessions();

  Future<List<AssistantChannelMessage>> fetchHistory(String sessionId);

  Future<AssistantChannelAuditSnapshot> fetchAudit();
}

class AssistantChannelApi implements AssistantChannelReader {
  AssistantChannelApi({http.Client? client})
    : _client = client ?? http.Client();

  static final AssistantChannelApi instance = AssistantChannelApi();

  final http.Client _client;

  static const _root = '/assistant-channel';

  @override
  Future<List<AssistantChannelSession>> fetchSessions() async {
    final json = await _get('$_root/sessions');
    return _records(
      json['sessions'],
    ).map(AssistantChannelSession.fromJson).toList(growable: false);
  }

  @override
  Future<List<AssistantChannelMessage>> fetchHistory(String sessionId) async {
    final cleanSessionId = sessionId.trim();
    if (cleanSessionId.isEmpty) return const [];

    final messages = <AssistantChannelMessage>[];
    final seenCursors = <int>{};
    int? beforeId;
    do {
      final json = await _get(
        '$_root/history',
        query: {
          'session_id': cleanSessionId,
          if (beforeId != null) 'before_id': '$beforeId',
        },
      );
      messages.addAll(
        _records(json['messages']).map(AssistantChannelMessage.fromJson),
      );
      final hasMore = json['has_more'] == true;
      final cursor = _asInt(json['next_before_id']);
      if (!hasMore || cursor == null || !seenCursors.add(cursor)) break;
      beforeId = cursor;
    } while (true);

    messages.sort((a, b) => a.id.compareTo(b.id));
    return messages;
  }

  @override
  Future<AssistantChannelAuditSnapshot> fetchAudit() async {
    final responses = await Future.wait([
      _get('$_root/memories'),
      _get('$_root/notes'),
      _get('$_root/tool-events'),
      _get('$_root/traces'),
      _get('$_root/status'),
    ]);
    return AssistantChannelAuditSnapshot(
      bridges: _records(
        responses[0]['memories'],
      ).map(AssistantChannelBridge.fromJson).toList(growable: false),
      notes: _records(responses[1]['notes']),
      toolEvents: _records(responses[2]['tool_events']),
      traces: _records(
        responses[3]['traces'],
      ).map(AssistantChannelTrace.fromJson).toList(growable: false),
      status: AssistantChannelStatus.fromJson(responses[4]),
    );
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final base = Uri.parse(ServerConfig.url(8816, path));
    final uri = query == null ? base : base.replace(queryParameters: query);
    http.Response response;
    try {
      response = await _client
          .get(uri, headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      throw AssistantChannelException('连不上 AI 协作记录', cause: error);
    }
    if (response.statusCode != 200) {
      throw AssistantChannelException(
        'AI 协作记录返回 ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) throw const FormatException('not an object');
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));
      if (json['ok'] == false) {
        throw const FormatException('ok=false');
      }
      return json;
    } catch (error) {
      throw AssistantChannelException('AI 协作记录响应格式不正确', cause: error);
    }
  }
}

class AssistantChannelException implements Exception {
  const AssistantChannelException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => message;
}

class AssistantChannelSession {
  const AssistantChannelSession({
    required this.sessionId,
    required this.messageCount,
    required this.createdAt,
    required this.firstMessageAt,
    required this.lastMessageAt,
  });

  factory AssistantChannelSession.fromJson(Map<String, dynamic> json) {
    return AssistantChannelSession(
      sessionId: _asString(json['session_id']),
      messageCount: _asInt(json['message_count']) ?? 0,
      createdAt: _asString(json['created_at']),
      firstMessageAt: _asString(json['first_message_at']),
      lastMessageAt: _asString(json['last_message_at']),
    );
  }

  final String sessionId;
  final int messageCount;
  final String createdAt;
  final String firstMessageAt;
  final String lastMessageAt;
}

class AssistantChannelMessage {
  const AssistantChannelMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.speaker,
    required this.content,
    required this.createdAt,
  });

  factory AssistantChannelMessage.fromJson(Map<String, dynamic> json) {
    return AssistantChannelMessage(
      id: _asInt(json['id']) ?? 0,
      sessionId: _asString(json['session_id']),
      role: _asString(json['role']),
      speaker: _asString(json['speaker']),
      content: _asString(json['content']),
      createdAt: _asString(json['created_at']),
    );
  }

  final int id;
  final String sessionId;
  final String role;
  final String speaker;
  final String content;
  final String createdAt;

  bool get isChatGpt => role.toLowerCase() == 'chatgpt';
}

class AssistantChannelSourceRef {
  const AssistantChannelSourceRef({
    required this.sessionId,
    required this.messageId,
    required this.role,
    required this.createdAt,
  });

  factory AssistantChannelSourceRef.fromJson(Map<String, dynamic> json) {
    return AssistantChannelSourceRef(
      sessionId: _asString(json['session_id']),
      messageId: _asInt(json['message_id']) ?? 0,
      role: _asString(json['role']),
      createdAt: _asString(json['created_at']),
    );
  }

  final String sessionId;
  final int messageId;
  final String role;
  final String createdAt;
}

class AssistantChannelBridge {
  const AssistantChannelBridge({
    required this.versionId,
    required this.previousVersionId,
    required this.memoryId,
    required this.topic,
    required this.summary,
    required this.detail,
    required this.status,
    required this.revisionAction,
    required this.createdAt,
    required this.sourceRefs,
  });

  factory AssistantChannelBridge.fromJson(Map<String, dynamic> json) {
    return AssistantChannelBridge(
      versionId: _asInt(json['id']) ?? 0,
      previousVersionId: _asInt(json['previous_version_id']),
      memoryId: _asString(json['memory_id']),
      topic: _asString(json['topic']),
      summary: _asString(json['summary']),
      detail: _asString(json['detail']),
      status: _asString(json['status']),
      revisionAction: _asString(json['revision_action']),
      createdAt: _asString(json['created_at']),
      sourceRefs: _records(
        json['source_refs'],
      ).map(AssistantChannelSourceRef.fromJson).toList(growable: false),
    );
  }

  final int versionId;
  final int? previousVersionId;
  final String memoryId;
  final String topic;
  final String summary;
  final String detail;
  final String status;
  final String revisionAction;
  final String createdAt;
  final List<AssistantChannelSourceRef> sourceRefs;
}

enum AssistantChannelRecallKind { automatic, assistant }

class AssistantChannelTrace {
  const AssistantChannelTrace({
    required this.id,
    required this.traceType,
    required this.surface,
    required this.memoryId,
    required this.versionId,
    required this.matchReason,
    required this.createdAt,
    required this.sourceRefs,
  });

  factory AssistantChannelTrace.fromJson(Map<String, dynamic> json) {
    return AssistantChannelTrace(
      id: _asInt(json['id']) ?? 0,
      traceType: _asString(json['trace_type']),
      surface: _asString(json['surface']),
      memoryId: _asString(json['memory_id']),
      versionId: _asInt(json['version_id']),
      matchReason: _asString(json['match_reason']),
      createdAt: _asString(json['created_at']),
      sourceRefs: _records(
        json['source_refs'],
      ).map(AssistantChannelSourceRef.fromJson).toList(growable: false),
    );
  }

  final int id;
  final String traceType;
  final String surface;
  final String memoryId;
  final int? versionId;
  final String matchReason;
  final String createdAt;
  final List<AssistantChannelSourceRef> sourceRefs;

  AssistantChannelRecallKind get recallKind {
    final marker = traceType.toLowerCase();
    return marker.contains('auto') || marker.contains('runtime')
        ? AssistantChannelRecallKind.automatic
        : AssistantChannelRecallKind.assistant;
  }
}

class AssistantChannelStatus {
  const AssistantChannelStatus({
    required this.quickCheck,
    required this.counts,
    required this.lastBackupAt,
  });

  factory AssistantChannelStatus.fromJson(Map<String, dynamic> json) {
    final backup = _asMap(json['last_successful_backup']);
    return AssistantChannelStatus(
      quickCheck: _asString(json['quick_check']),
      counts: _asMap(
        json['counts'],
      ).map((key, value) => MapEntry(key, _asInt(value) ?? 0)),
      lastBackupAt: _asString(backup['created_at']),
    );
  }

  final String quickCheck;
  final Map<String, int> counts;
  final String lastBackupAt;
}

class AssistantChannelAuditSnapshot {
  const AssistantChannelAuditSnapshot({
    required this.bridges,
    required this.notes,
    required this.toolEvents,
    required this.traces,
    required this.status,
  });

  final List<AssistantChannelBridge> bridges;
  final List<Map<String, dynamic>> notes;
  final List<Map<String, dynamic>> toolEvents;
  final List<AssistantChannelTrace> traces;
  final AssistantChannelStatus status;
}

List<Map<String, dynamic>> _records(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (entry) => entry.map((key, value) => MapEntry(key.toString(), value)),
      )
      .toList(growable: false);
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _asString(Object? value) => value?.toString().trim() ?? '';

int? _asInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};
