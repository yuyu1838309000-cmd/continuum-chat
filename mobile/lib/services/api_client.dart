import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_config.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class SseEvent {
  const SseEvent(this.type, this.data, this.payload);

  final String type;
  final Object? data;
  final Map<String, dynamic> payload;
}

Stream<String> _sseData(Stream<String> lines) async* {
  final dataLines = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      if (dataLines.isNotEmpty) {
        yield dataLines.join('\n');
        dataLines.clear();
      }
      continue;
    }
    if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
    }
  }
  if (dataLines.isNotEmpty) yield dataLines.join('\n');
}

class ApiClient {
  ApiClient(this.config, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final ServerConfig config;
  final http.Client _http;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    if (config.token.trim().isNotEmpty)
      'Authorization': 'Bearer ${config.token.trim()}',
  };

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
    bool memory = false,
  }) async {
    final response = await _http.get(
      memory ? config.memoryUri(path, query) : config.runtimeUri(path, query),
      headers: _headers,
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    bool memory = false,
  }) async {
    final response = await _http.post(
      memory ? config.memoryUri(path) : config.runtimeUri(path),
      headers: _headers,
      body: jsonEncode(body),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> putJson(
    String path,
    Map<String, dynamic> body, {
    bool memory = false,
  }) async {
    final response = await _http.put(
      memory ? config.memoryUri(path) : config.runtimeUri(path),
      headers: _headers,
      body: jsonEncode(body),
    );
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> deleteJson(
    String path, {
    bool memory = false,
  }) async {
    final response = await _http.delete(
      memory ? config.memoryUri(path) : config.runtimeUri(path),
      headers: _headers,
    );
    return _decodeResponse(response);
  }

  Stream<SseEvent> chat(String message, {String conversationId = 'default'}) {
    final controller = StreamController<SseEvent>();
    () async {
      try {
        final request = http.Request('POST', config.runtimeUri('/chat'))
          ..headers.addAll({..._headers, 'Accept': 'text/event-stream'})
          ..body = jsonEncode({
            'message': message,
            'conversation_id': conversationId,
          });
        final response = await _http.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.stream.bytesToString();
          throw ApiException(
            _errorMessage(body, response.statusCode),
            statusCode: response.statusCode,
          );
        }
        final lines = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final raw in _sseData(lines)) {
          if (raw.isEmpty || raw == '[DONE]') continue;
          final decoded = jsonDecode(raw);
          if (decoded is! Map<String, dynamic>) continue;
          final type = decoded['type']?.toString() ?? 'message';
          if (type == 'error') {
            throw ApiException(decoded['error']?.toString() ?? 'Chat failed.');
          }
          controller.add(SseEvent(type, decoded['data'], decoded));
        }
        await controller.close();
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
        await controller.close();
      }
    }();
    return controller.stream;
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        _errorMessage(response.body, response.statusCode),
        statusCode: response.statusCode,
      );
    }
    if (response.body.trim().isEmpty) return const {};
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Expected a JSON object response.');
  }

  static String _errorMessage(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } on FormatException {
      // Fall through to the status-based message for non-JSON responses.
    }
    return 'Request failed ($statusCode).';
  }

  void close() => _http.close();
}
