import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

class RuntimeHistoryException implements Exception {
  const RuntimeHistoryException(
    this.message, {
    this.statusCode,
    this.kind = 'contract',
  });

  final String message;
  final int? statusCode;
  final String kind;

  @override
  String toString() => message;
}

class RuntimeHistoryApi {
  RuntimeHistoryApi({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> capabilities() => _get('/runtime/capabilities');

  Future<Map<String, dynamic>> epochs({int? beforeOrdinal, int limit = 50}) =>
      _get(
        '/runtime/epochs',
        query: _query({
          'thread_id': 'main',
          'before_ordinal': beforeOrdinal?.toString(),
          'limit': '$limit',
        }),
      );

  Future<Map<String, dynamic>> epochDetail(
    String epochId, {
    int afterSeq = 0,
    int limit = 200,
  }) => _get(
    '/runtime/epochs/${Uri.encodeComponent(epochId)}',
    query: {'thread_id': 'main', 'after_seq': '$afterSeq', 'limit': '$limit'},
  );

  Future<Map<String, dynamic>> folders() => _get('/runtime/archive-folders');

  Future<Map<String, dynamic>> bootstrapFolders(
    List<Map<String, dynamic>> folders,
  ) => _post('/runtime/archive-folders/bootstrap', {'folders': folders});

  Future<Map<String, dynamic>> assignFolder({
    required List<String> epochIds,
    required String? folderId,
    required String commandId,
  }) => _post('/runtime/archive-folders/assign', {
    'thread_id': 'main',
    'epoch_ids': epochIds,
    'folder_id': folderId,
    'command_id': commandId,
  });

  Future<Map<String, dynamic>> createFolder({
    required String name,
    required String commandId,
  }) => _post('/runtime/archive-folders', {
    'thread_id': 'main',
    'name': name,
    'command_id': commandId,
  });

  Future<Map<String, dynamic>> renameFolder({
    required String folderId,
    required String name,
    required String commandId,
  }) => _patch('/runtime/archive-folders/${Uri.encodeComponent(folderId)}', {
    'thread_id': 'main',
    'name': name,
    'command_id': commandId,
  });

  Future<Map<String, dynamic>> deleteFolder({
    required String folderId,
    required String commandId,
  }) => _delete('/runtime/archive-folders/${Uri.encodeComponent(folderId)}', {
    'thread_id': 'main',
    'command_id': commandId,
  });

  Future<Map<String, dynamic>> deleteEpoch({
    required String epochId,
    required String commandId,
  }) => _delete('/runtime/epochs/${Uri.encodeComponent(epochId)}', {
    'thread_id': 'main',
    'command_id': commandId,
  });

  Future<Map<String, dynamic>> restoreEpoch({
    required String epochId,
    required String commandId,
  }) => _post('/runtime/epochs/${Uri.encodeComponent(epochId)}/restore', {
    'thread_id': 'main',
    'command_id': commandId,
  });

  Future<Map<String, dynamic>> trash({int? beforeOrdinal, int limit = 50}) =>
      _get(
        '/runtime/epochs/trash',
        query: _query({
          'before_ordinal': beforeOrdinal?.toString(),
          'limit': '$limit',
        }),
      );

  Future<Map<String, dynamic>> search(
    String queryText, {
    int limit = 30,
    String? cursor,
  }) => _get(
    '/runtime/history/search',
    query: _query({'q': queryText, 'limit': '$limit', 'cursor': cursor}),
  );

  Future<Map<String, dynamic>> calendar({
    required DateTime start,
    required DateTime end,
    required int timezoneOffsetMinutes,
  }) => _get(
    '/runtime/history/calendar',
    query: {
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'tz_offset_minutes': '$timezoneOffsetMinutes',
    },
  );

  Future<Map<String, dynamic>> messages({
    required DateTime start,
    required DateTime end,
    int limit = 200,
    String? cursor,
  }) => _get(
    '/runtime/history/messages',
    query: _query({
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'limit': '$limit',
      'cursor': cursor,
    }),
  );

  Future<Map<String, dynamic>> legacyInfo() => _get('/runtime/legacy-history');

  Future<Map<String, dynamic>> legacyGroups({int limit = 50, String? cursor}) =>
      _get(
        '/runtime/legacy-history/groups',
        query: _query({'limit': '$limit', 'cursor': cursor}),
      );

  Future<Map<String, dynamic>> legacyGroupDetail(
    String groupId, {
    int afterId = 0,
    int limit = 200,
  }) => _get(
    '/runtime/legacy-history/groups/${Uri.encodeComponent(groupId)}',
    query: {'after_id': '$afterId', 'limit': '$limit'},
  );

  Future<Map<String, dynamic>> legacySearch(
    String queryText, {
    int limit = 30,
    String? cursor,
  }) => _get(
    '/runtime/legacy-history/search',
    query: _query({'q': queryText, 'limit': '$limit', 'cursor': cursor}),
  );

  Future<Map<String, dynamic>> legacyCalendar({
    required DateTime start,
    required DateTime end,
    required int timezoneOffsetMinutes,
  }) => _get(
    '/runtime/legacy-history/calendar',
    query: {
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'tz_offset_minutes': '$timezoneOffsetMinutes',
    },
  );

  Future<Map<String, dynamic>> legacyMessages({
    required DateTime start,
    required DateTime end,
    int limit = 200,
    String? cursor,
  }) => _get(
    '/runtime/legacy-history/messages',
    query: _query({
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'limit': '$limit',
      'cursor': cursor,
    }),
  );

  Uri uriFor(String path, [Map<String, String>? query]) => Uri.parse(
    ServerConfig.runtimeUrl(path),
  ).replace(queryParameters: query?.isEmpty == true ? null : query);

  Map<String, String> _query(Map<String, String?> values) {
    final result = <String, String>{};
    for (final entry in values.entries) {
      final value = entry.value;
      if (value != null) result[entry.key] = value;
    }
    return result;
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = uriFor(path, query);
    RuntimeHistoryException? lastTransportError;
    for (var attempt = 0; attempt < 2; attempt++) {
      http.Response response;
      try {
        response = await _client
            .get(uri, headers: ChatApi.authHeaders())
            .timeout(timeout);
      } on SocketException catch (error) {
        lastTransportError = RuntimeHistoryException(
          error.message,
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      } on HttpException catch (error) {
        lastTransportError = RuntimeHistoryException(
          error.message,
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      } on http.ClientException catch (error) {
        lastTransportError = RuntimeHistoryException(
          error.message,
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      } on TimeoutException {
        lastTransportError = const RuntimeHistoryException(
          '历史接口请求超时',
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      }
      final body = _decode(response);
      if (response.statusCode != 200) {
        throw RuntimeHistoryException(
          body['error']?.toString() ?? '历史接口请求失败',
          statusCode: response.statusCode,
          kind: 'http',
        );
      }
      if (body['ok'] != true) {
        throw RuntimeHistoryException(
          body['error']?.toString() ?? '历史接口契约无效',
          statusCode: response.statusCode,
        );
      }
      return body;
    }
    throw lastTransportError ??
        const RuntimeHistoryException('历史接口请求失败', kind: 'transport');
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload,
  ) => _mutate('POST', path, payload);

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> payload,
  ) => _mutate('PATCH', path, payload);

  Future<Map<String, dynamic>> _delete(
    String path,
    Map<String, dynamic> payload,
  ) => _mutate('DELETE', path, payload);

  Future<Map<String, dynamic>> _mutate(
    String method,
    String path,
    Map<String, dynamic> payload,
  ) async {
    RuntimeHistoryException? lastTransportError;
    for (var attempt = 0; attempt < 2; attempt++) {
      http.Response response;
      try {
        final request = http.Request(method, uriFor(path))
          ..headers.addAll(
            ChatApi.authHeaders({'Content-Type': 'application/json'}),
          )
          ..body = jsonEncode(payload);
        final streamed = await _client.send(request).timeout(timeout);
        response = await http.Response.fromStream(streamed);
      } on SocketException catch (error) {
        lastTransportError = RuntimeHistoryException(
          error.message,
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      } on HttpException catch (error) {
        lastTransportError = RuntimeHistoryException(
          error.message,
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      } on http.ClientException catch (error) {
        lastTransportError = RuntimeHistoryException(
          error.message,
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      } on TimeoutException {
        lastTransportError = const RuntimeHistoryException(
          '历史接口请求超时',
          kind: 'transport',
        );
        if (attempt == 0) continue;
        throw lastTransportError;
      }
      final body = _decode(response);
      if (response.statusCode != 200) {
        throw RuntimeHistoryException(
          body['error']?.toString() ?? '历史接口请求失败',
          statusCode: response.statusCode,
          kind: 'http',
        );
      }
      if (body['ok'] != true) {
        throw RuntimeHistoryException(
          body['error']?.toString() ?? '历史接口契约无效',
          statusCode: response.statusCode,
        );
      }
      return body;
    }
    throw lastTransportError ??
        const RuntimeHistoryException('历史接口请求失败', kind: 'transport');
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      // Converted below into one stable contract error.
    }
    throw RuntimeHistoryException(
      '历史接口返回了无效 JSON',
      statusCode: response.statusCode,
    );
  }
}
