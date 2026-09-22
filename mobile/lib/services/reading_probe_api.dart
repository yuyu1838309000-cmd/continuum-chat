import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 共读技术探针原生桥。
///
/// 只读取 App 私有本地采样结果；探针本身不访问服务器、不调用模型。
class ReadingProbeApi {
  ReadingProbeApi._();

  static const MethodChannel _channel = MethodChannel(
    'continuum/reading_probe',
  );

  static Future<Map<String, dynamic>> state() => _invoke('getState');

  static Future<Map<String, dynamic>> setEnabled(bool enabled) =>
      _invoke('setEnabled', {'enabled': enabled});

  static Future<Map<String, dynamic>> clear() => _invoke('clear');

  static Future<Map<String, dynamic>> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final raw = await _channel.invokeMethod<String>(method, arguments);
      if (raw == null || raw.trim().isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (e) {
      debugPrint('[reading-probe] $method error: $e');
    }
    return const {};
  }
}
