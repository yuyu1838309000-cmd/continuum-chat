import '../models/personal_space.dart';
import 'api_cache.dart';
import 'server_config.dart';

/// 个人空间接口（后端 8820 /diary、/whisper，只读展示，不改后端）。
/// 服务器地址从配置中心动态拼（ServerConfig.url），换服务器不用重编译。
/// 风格照 memory_api.dart：静态方法、8s 超时、失败返回 null。
class PersonalSpaceApi {
  PersonalSpaceApi._();

  static String _url(String path) => ServerConfig.url(8820, path);

  /// GET /diary → 日记列表（后端 date 倒序），失败返回 null。
  static Future<List<DiaryEntry>?> diary({
    void Function(List<DiaryEntry> entries)? onCached,
  }) async {
    final url = _url('/diary');
    final cachedRaw = await ApiCache.read(url);
    final cached = _parseDiary(cachedRaw);
    if (cached != null) {
      onCached?.call(cached);
      if (!await ApiCache.isExpired(url)) return cached;
    }

    final freshRaw = await ApiCache.fetchJson(url);
    return freshRaw == null ? cached : _parseDiary(freshRaw);
  }

  /// GET /whisper → 想说的话（后端 pinned=1 在前、created_at 倒序），失败返回 null。
  static Future<List<Whisper>?> whisper({
    void Function(List<Whisper> entries)? onCached,
  }) async {
    final url = _url('/whisper');
    final cachedRaw = await ApiCache.read(url);
    final cached = _parseWhispers(cachedRaw);
    if (cached != null) {
      onCached?.call(cached);
      if (!await ApiCache.isExpired(url)) return cached;
    }

    final freshRaw = await ApiCache.fetchJson(url);
    return freshRaw == null ? cached : _parseWhispers(freshRaw);
  }

  static List<DiaryEntry>? _parseDiary(Object? raw) {
    if (raw is! List) return null;
    return [
      for (final entry in raw)
        if (entry is Map<String, dynamic>) DiaryEntry.fromJson(entry),
    ];
  }

  static List<Whisper>? _parseWhispers(Object? raw) {
    if (raw is! List) return null;
    return [
      for (final entry in raw)
        if (entry is Map<String, dynamic>) Whisper.fromJson(entry),
    ];
  }
}
