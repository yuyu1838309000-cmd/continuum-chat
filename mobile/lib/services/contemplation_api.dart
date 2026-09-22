import 'api_cache.dart';
import 'server_config.dart';

/// 沉思室只读接口：只拉条数，不拉内容（用户看不到沉思内容）。
/// 8820 无认证，和 personal_space_api 一致直接请求。
class ContemplationApi {
  ContemplationApi._();

  static String get _countUrl => ServerConfig.url(8820, '/contemplation/count');

  static Future<int?> count({void Function(int count)? onCached}) async {
    final cachedRaw = await ApiCache.read(_countUrl);
    final cached = _parseCount(cachedRaw);
    if (cached != null) {
      onCached?.call(cached);
      if (!await ApiCache.isExpired(_countUrl)) return cached;
    }

    final freshRaw = await ApiCache.fetchJson(
      _countUrl,
      timeout: const Duration(seconds: 6),
    );
    return freshRaw == null ? cached : _parseCount(freshRaw);
  }

  static int? _parseCount(Object? raw) =>
      raw is Map<String, dynamic> ? (raw['count'] as num?)?.toInt() : null;
}
