import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/self_prompt.dart';
import 'api_cache.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// 自我提示接口（8816 GET/POST /self-prompt，~/self_prompt.json）。
/// AI 助手的身份认知（system_prompt）+ 平时想放的记忆（memories），
/// 服务端 build_chat_messages 拼对话时作为【系统提示词】分区注入最顶上。
/// 与所有 8816 请求一致，带 X-Token（ChatApi.authHeaders）。
class SelfPromptApi {
  SelfPromptApi._();

  static String get _url => ServerConfig.url(8816, '/self-prompt');

  /// GET /self-prompt → {system_prompt, memories[]}；失败返回 null。
  static Future<SelfPrompt?> fetch() async {
    try {
      final resp = await http
          .get(Uri.parse(_url), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null) return null;
      return SelfPrompt.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// POST /self-prompt：字段级合并保存（只更新 body 里出现的字段）。
  /// 返回保存后的完整数据（服务器回），失败返回 null。
  static Future<SelfPrompt?> save({
    String? systemPrompt,
    List<String>? memories,
  }) async {
    try {
      final body = <String, dynamic>{
        'system_prompt': ?systemPrompt,
        'memories': ?memories,
      };
      final resp = await http
          .post(
            Uri.parse(_url),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null) return null;
      // /self-prompt 的列表页会先读 5 分钟页面缓存。写成功后必须
      // 同步回写同一 URL，否则删除/编辑后重新进页面会被旧缓存“复活”。
      await ApiCache.write(_url, j);
      return SelfPrompt.fromJson(j);
    } catch (_) {
      return null;
    }
  }
}
