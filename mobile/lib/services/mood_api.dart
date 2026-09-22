import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/mood.dart';
import 'api_cache.dart';
import 'server_config.dart';

/// Continuum Chat情绪接口（后端 8820 /mood/*，只读，不改后端）。
/// 服务器地址从配置中心动态拼（ServerConfig.url），换服务器不用重编译。
class MoodApi {
  MoodApi._();

  static String _url(String path) => ServerConfig.url(8820, path);

  /// GET /mood/current → 最新一条情绪，失败返回 null。
  static Future<MoodEntry?> current({
    void Function(MoodEntry mood)? onCached,
  }) async {
    final url = _url('/mood/current');
    final cachedRaw = await ApiCache.read(url);
    final cached = _parseCurrent(cachedRaw);
    if (cached != null) {
      onCached?.call(cached);
      if (!await ApiCache.isExpired(url)) return cached;
    }

    final freshRaw = await ApiCache.fetchJson(url);
    return freshRaw == null ? cached : _parseCurrent(freshRaw);
  }

  static MoodEntry? _parseCurrent(Object? raw) =>
      raw is Map<String, dynamic> && raw['id'] != null
      ? MoodEntry.fromJson(raw)
      : null;

  /// GET /mood/history?limit=N → 最近 N 条（含 current，去重由前端做），失败返回 null。
  static Future<List<MoodEntry>?> history({int limit = 2}) async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/mood/history?limit=$limit')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(resp.body) as List<dynamic>?;
      if (raw == null) return null;
      return [
        for (final e in raw)
          if (e is Map<String, dynamic> && e['id'] != null)
            MoodEntry.fromJson(e),
      ];
    } catch (_) {
      return null;
    }
  }
}
