import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

/// 上下文拼接配置读写（8816 /context-layout）。
/// 8816 请求统一带 ChatApi.authHeaders。
class ContextLayoutApi {
  ContextLayoutApi._();

  static String get _url => ServerConfig.url(8816, '/context-layout');

  static Future<Map<String, dynamic>?> fetch() async {
    try {
      final resp = await http
          .get(Uri.parse(_url), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      return j;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> save(Map<String, dynamic> cfg) async {
    try {
      final resp = await http
          .post(
            Uri.parse(_url),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(cfg),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> reset() => save({'reset': true});
}
