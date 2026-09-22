import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/bottle.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// 提问瓶接口（v0.2.151）。
/// - 读：GET 8820 /bottle/questions（维度统计 + 最新未答 + 最近已答）
/// - 写：POST 8816 /bottle/answer、/bottle/skip（8816 落库 8820 + 记事件注入AI 助手对话）
class BottleApi {
  BottleApi._();

  static String _url(String path) => ServerConfig.url(8820, path);

  /// 拉提问瓶数据（维度统计 + 最新未答 + 最近已答），失败返回 null。
  static Future<BottleData?> fetch({String? dimension}) async {
    try {
      final path = dimension == null || dimension.trim().isEmpty
          ? '/bottle/questions'
          : '/bottle/questions?dimension=${Uri.encodeQueryComponent(dimension.trim())}';
      final resp = await http
          .get(Uri.parse(_url(path)))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map<String, dynamic>) return null;
      return BottleData.fromJson(j);
    } catch (e) {
      debugPrint('[bottle] fetch error: $e');
      return null;
    }
  }

  /// 用户回答问题：8816 落库 8820 + 记事件供AI 助手注入。
  /// 返回服务器响应 map（含 ok/card_id），失败返回 null。
  static Future<Map<String, dynamic>?> answer({
    required int id,
    required String answer,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/bottle/answer')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'id': id, 'answer': answer}),
          )
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      return j is Map<String, dynamic> ? Map<String, dynamic>.from(j) : null;
    } catch (e) {
      debugPrint('[bottle] answer error: $e');
      return null;
    }
  }

  /// 用户点「不回答」：8816 标记跳过（不写卡、不注入），翻到下一条。
  static Future<bool> skip({required int id}) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/bottle/skip')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'id': id}),
          )
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      return j is Map<String, dynamic> && j['ok'] == true;
    } catch (e) {
      debugPrint('[bottle] skip error: $e');
      return false;
    }
  }
}
