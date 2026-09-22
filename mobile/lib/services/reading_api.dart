import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/reading_book.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// 一起读接口（v0.2.148）。
/// - 数据源：read_data.json 经 8070 static 只读拉取（read-mcp 8812 同源副本）
/// - 用户打星/选情绪/写短评：POST 8816 /read/activity（source=participant，复用音乐上报机制）
/// - 魔道祖师/墨香铜臭 BLOCKED 红线与 read-mcp 一致，前端展示同样过滤
class ReadingApi {
  ReadingApi._();

  static const List<String> blocked = ['魔道祖师', '墨香铜臭'];

  static bool isBlocked(String text) {
    if (text.isEmpty) return false;
    return blocked.any(text.contains);
  }

  /// 拉全部书（read_data.json 以书名为 key），过滤红线，按 updated 倒序。
  /// 失败返回 null（连不上），成功返回列表（可能为空）。
  static Future<List<ReadingBook>?> books() async {
    try {
      final resp = await http
          .get(Uri.parse(ServerConfig.url(8070, '/read_data.json')))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map) return null;
      final books = <ReadingBook>[];
      j.forEach((k, v) {
        if (v is! Map<String, dynamic>) return;
        final b = ReadingBook.fromJson(v);
        if (isBlocked(b.title)) return;
        if (isBlocked(b.author)) return;
        books.add(b);
      });
      books.sort((a, b) => b.updated.compareTo(a.updated));
      return books;
    } catch (e) {
      debugPrint('[reading] books error: $e');
      return null;
    }
  }

  /// 用户打星/选情绪/写短评上报 8816（只能操作自己的，服务器也校验 who=participant）。
  static Future<Map<String, dynamic>?> reportActivity({
    required String title,
    int score = 0,
    String mood = '',
    String comment = '',
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/read/activity')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'title': title,
              'who': 'participant',
              'score': score,
              'mood': mood,
              'comment': comment,
            }),
          )
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map) return null;
      return Map<String, dynamic>.from(j);
    } catch (e) {
      debugPrint('[reading] report error: $e');
      return null;
    }
  }
}
