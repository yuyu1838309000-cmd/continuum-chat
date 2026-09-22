import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局"显示气泡时间戳"开关。默认显示，设置页控制，聊天页即时刷新。
class TimestampPref {
  static const String key = 'show_message_timestamps';
  static final ValueNotifier<bool> show = ValueNotifier(true);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    show.value = prefs.getBool(key) ?? true;
  }

  static Future<void> set(bool v) async {
    show.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, v);
  }
}
