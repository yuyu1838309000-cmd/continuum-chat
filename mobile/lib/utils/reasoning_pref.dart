import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局"显示思考气泡"开关。默认显示，设置页控制，聊天页即时刷新。
/// 只影响显示层：关掉后思考内容照常流式累积（reply.reasoning 不变），只是不渲染。
class ReasoningPref {
  static const String key = 'show_reasoning_bubbles';
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
