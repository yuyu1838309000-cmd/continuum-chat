import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/pixel_home.dart';
import 'server_config.dart';

/// 像素小家状态：8089 static 直读 state_new.json（原生 App 无 CORS 问题）。
/// 失败返回 null，页面侧展示友好提示。
class PixelHomeApi {
  PixelHomeApi._();

  static Future<PixelHome?> fetch() async {
    try {
      final resp = await http
          .get(Uri.parse(ServerConfig.url(8089, '/state_new.json')))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      return PixelHome.fromJson(decoded);
    } catch (e) {
      debugPrint('[pixelhome] fetch error: $e');
      return null;
    }
  }
}
