import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/prompt_entry.dart';
import 'server_config.dart';

/// 系统记忆管理接口（服务器 8814）
class PromptApi {
  static String get manageUrl => ServerConfig.url(8814, '/prompts');

  /// 拉取 active 的记忆配置，返回 (名字, 分区列表)；失败返回 null
  static Future<({String name, List<PromptSection> sections})?>
  fetchActive() async {
    try {
      final resp = await http
          .get(Uri.parse(manageUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      final active = json?['active'] as String?;
      final prompts = json?['prompts'] as Map<String, dynamic>?;
      final entry = prompts?[active] as Map<String, dynamic>?;
      final raw = entry?['sections'] as List<dynamic>?;
      if (active == null || raw == null) return null;
      final sections = raw
          .map((e) => PromptSection.fromJson(e as Map<String, dynamic>))
          .toList();
      return (name: active, sections: sections);
    } catch (_) {
      return null;
    }
  }

  /// 保存整个分区结构，返回是否成功
  static Future<bool> save(String name, List<PromptSection> sections) async {
    try {
      final resp = await http
          .post(
            Uri.parse(manageUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'sections': sections.map((e) => e.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
