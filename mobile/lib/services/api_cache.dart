import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Continuum Chat页面级 API 缓存：数据页打开秒显旧数据 + 后台静默拉新。
///
/// 模式照抄 ChatStore 的文件缓存：
/// - 文件存 getApplicationDocumentsDirectory() 下，命名 `api_cache_<md5(url)>.json`
/// - 内容 {"cached_at": ISO 时间戳, "data": 接口原始返回}
///
/// 页面用法（写操作不缓存）：
/// 1. `read(url)` 有缓存直接秒显（即使已过期也显示，体验优先）
/// 2. `fetchJson(url)` 后台静默拉新，成功自动写缓存，失败保留旧缓存
///
/// 所有读写一律 try/catch 静默：失败返回 null / 不写，绝不抛异常、绝不卡 UI。
class ApiCache {
  ApiCache._();

  /// 默认过期时间：5 分钟（`isExpired` 用，页面按需判断）。
  static const Duration defaultTtl = Duration(minutes: 5);

  static Future<File> _fileFor(String url) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/api_cache_${_md5Hex(utf8.encode(url))}.json');
  }

  /// 读缓存，返回接口原始返回（`data` 字段，Map/List/标量）。
  /// 无缓存 / 文件损坏 / 解析失败一律返回 null，不抛异常。
  static Future<Object?> read(String url) async {
    try {
      final file = await _fileFor(url);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return decoded['data'];
    } catch (_) {
      return null;
    }
  }

  /// 写缓存：{"cached_at": ISO 时间戳, "data": 接口原始返回}。
  /// [data] 为 null 时不写；写入失败静默，下次再试。
  static Future<void> write(String url, Object data) async {
    try {
      final file = await _fileFor(url);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'cached_at': DateTime.now().toIso8601String(),
          'data': data,
        }),
        flush: true,
      );
    } catch (_) {
      // 落盘失败不致命，旧缓存保留不动
    }
  }

  /// 缓存是否过期。无缓存 / 读不到时间戳一律视为过期（宁刷新不错过）。
  static Future<bool> isExpired(String url, {Duration ttl = defaultTtl}) async {
    try {
      final file = await _fileFor(url);
      if (!await file.exists()) return true;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return true;
      final cachedAt = DateTime.tryParse(
        decoded['cached_at']?.toString() ?? '',
      );
      if (cachedAt == null) return true;
      return DateTime.now().difference(cachedAt) > ttl;
    } catch (_) {
      return true;
    }
  }

  /// GET 拉取接口原始 JSON：成功写缓存并返回解码后的 `data`，
  /// 网络失败 / 非 200 / 解析失败返回 null（旧缓存原样保留，不报错不白屏）。
  /// [utf8Body] 为 true 时按 UTF-8 解码（带中文的 static JSON / 8816 接口）。
  static Future<Object?> fetchJson(
    String url, {
    Map<String, String>? headers,
    bool utf8Body = false,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final resp = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(
        utf8Body ? utf8.decode(resp.bodyBytes) : resp.body,
      );
      if (decoded != null) await write(url, decoded);
      return decoded;
    } catch (_) {
      return null;
    }
  }
}

/// 32 位循环左移（MD5 用）。
int _rotl32(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;

/// 纯 Dart MD5（RFC 1321）。App 没引 crypto 包，这里内联实现，
/// 不新增任何依赖，用于缓存文件名里的 `<md5(url)>`。
String _md5Hex(List<int> input) {
  final msg = List<int>.from(input)..add(0x80);
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  // 原始消息长度（bit）按 64 位小端追加
  final bitLength = input.length * 8;
  for (var i = 0; i < 8; i++) {
    msg.add((bitLength >> (8 * i)) & 0xFF);
  }

  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;

  const s = <int>[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];

  const k = <int>[
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, //
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501, //
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, //
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, //
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, //
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, //
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, //
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, //
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, //
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, //
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, //
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, //
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, //
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1, //
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, //
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  for (var offset = 0; offset < msg.length; offset += 64) {
    final m = <int>[];
    for (var i = 0; i < 16; i++) {
      final o = offset + i * 4;
      m.add(
        msg[o] | (msg[o + 1] << 8) | (msg[o + 2] << 16) | (msg[o + 3] << 24),
      );
    }

    var a = a0;
    var b = b0;
    var c = c0;
    var d = d0;

    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      f = (f + a + k[i] + m[g]) & 0xFFFFFFFF;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl32(f, s[i])) & 0xFFFFFFFF;
    }

    a0 = (a0 + a) & 0xFFFFFFFF;
    b0 = (b0 + b) & 0xFFFFFFFF;
    c0 = (c0 + c) & 0xFFFFFFFF;
    d0 = (d0 + d) & 0xFFFFFFFF;
  }

  // 每个 32 位字按小端输出 4 个字节的十六进制
  String wordHex(int word) {
    final hex = word.toRadixString(16).padLeft(8, '0');
    return [
      for (var i = 0; i < 4; i++) hex.substring(6 - 2 * i, 8 - 2 * i),
    ].join();
  }

  return wordHex(a0) + wordHex(b0) + wordHex(c0) + wordHex(d0);
}
