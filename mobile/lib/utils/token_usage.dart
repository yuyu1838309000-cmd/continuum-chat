import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局"显示 token 用量"开关（模型配置页控制，气泡即时响应）。
/// ValueNotifier：开关改动 notify，聊天页 ValueListenableBuilder 包气泡即时刷新。
class TokenUsagePref {
  static const String key = 'show_token_usage';
  static final ValueNotifier<bool> show = ValueNotifier(false);

  /// 启动读一次（默认关）
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    show.value = prefs.getBool(key) ?? false;
  }

  /// 开关改动：本地即时 + 存 prefs
  static Future<void> set(bool v) async {
    show.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, v);
  }
}
