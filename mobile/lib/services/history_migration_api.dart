import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

class HistoryMigrationException implements Exception {
  const HistoryMigrationException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Stateless HTTP adapter for the isolated Agent Runtime history migration API.
class HistoryMigrationApi {
  const HistoryMigrationApi();

  Future<Map<String, dynamic>> requireCapability() async {
    final response = await http
        .get(
          Uri.parse(ServerConfig.url(8816, '/runtime/capabilities')),
          headers: ChatApi.authHeaders(),
        )
        .timeout(const Duration(seconds: 10));
    final body = _decode(response);
    final capability = body['history_migration'];
    if (response.statusCode != 200 ||
        capability is! Map ||
        capability['version'] != 1 ||
        capability['preview'] != true ||
        capability['import'] != true ||
        capability['status'] != true) {
      throw HistoryMigrationException(
        '当前服务器不支持历史聊天迁移 v1，已安全停止',
        statusCode: response.statusCode,
      );
    }
    return capability.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<Map<String, dynamic>> preview(Map<String, dynamic> snapshot) =>
      _post('/runtime/history-migration/preview', snapshot);

  Future<Map<String, dynamic>> importSnapshot(Map<String, dynamic> snapshot) =>
      _post('/runtime/history-migration/import', snapshot);

  Future<Map<String, dynamic>?> status(String snapshotId) async {
    final uri = Uri.parse(
      ServerConfig.url(8816, '/runtime/history-migration/status'),
    ).replace(queryParameters: {'snapshot_id': snapshotId});
    final response = await http
        .get(uri, headers: ChatApi.authHeaders())
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 404) return null;
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw HistoryMigrationException(
        body['error']?.toString() ?? '读取历史迁移状态失败',
        statusCode: response.statusCode,
      );
    }
    return body;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final jsonBytes = utf8.encode(jsonEncode(body));
    final compressed = gzip.encode(jsonBytes);
    final response = await http
        .post(
          Uri.parse(ServerConfig.url(8816, path)),
          headers: ChatApi.authHeaders({
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Encoding': 'gzip',
            'X-Continuum-Uncompressed-Length': jsonBytes.length.toString(),
          }),
          body: compressed,
        )
        .timeout(const Duration(minutes: 3));
    final decoded = _decode(response);
    if (response.statusCode != 200) {
      throw HistoryMigrationException(
        decoded['error']?.toString() ?? '历史聊天迁移请求失败',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      // Fall through to one stable transport error.
    }
    throw HistoryMigrationException(
      '历史聊天迁移接口返回了无效数据',
      statusCode: response.statusCode,
    );
  }
}
