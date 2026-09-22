import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'chat_api.dart';
import 'permission_center.dart';
import 'server_config.dart';

/// 应用内更新：
/// - 检查：GET 8816 /latest-version → {version, apkUrl, ...}；服务端版本真相
///   来自稳定下载位的真实 APK 元数据，测试构建或源码 pubspec 不参与稳定更新判定。
/// - 下载：http 流式下载到应用外部缓存目录，回调进度（0-1）
/// - 安装：FileProvider 授权 + ACTION_VIEW 唤起系统安装器（原生通道 continuum/permission_center installApk）
class AppUpdate {
  AppUpdate._();

  /// 版本号比较：latest 比 current 新返回 true。
  /// 支持 "0.2.104" / "0.2.104+104" 格式，逐段数字比较，缺段按 0。
  static bool isNewer(String latest, String current) {
    List<int> parse(String v) {
      final seg = v.trim().split('+').first.split('.');
      return [for (final s in seg) int.tryParse(s.trim()) ?? 0];
    }

    final a = parse(latest);
    final b = parse(current);
    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// 当前 App 版本号（package_info_plus，如 0.2.103）。读不到返回空串。
  static Future<String> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '';
    }
  }

  /// 服务器最新版本信息 {version, apkUrl}。失败抛异常由调用方提示。
  static Future<Map<String, String>> checkLatest() async {
    final resp = await http
        .get(
          Uri.parse(ServerConfig.url(8816, '/latest-version')),
          headers: ChatApi.authHeaders(),
        )
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('http ${resp.statusCode}');
    }
    final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return {
      'version': (j['version'] as String? ?? '').trim(),
      'apkUrl': (j['apkUrl'] as String? ?? '').trim(),
    };
  }

  /// 流式下载 APK 到应用外部缓存目录，回传进度（0-1），返回文件路径。
  /// 下载前清掉旧文件，避免残留包被安装器误读。
  static Future<String> download(
    String url, {
    required void Function(double progress) onProgress,
  }) async {
    // path_provider 2.1.x 无 getExternalCacheDirectory，用应用缓存目录
    // （FileProvider 已配 <cache-path>，授权系统安装器读取）
    final dir = await getApplicationCacheDirectory();
    final file = File('${dir.path}/continuum-update.apk');
    if (await file.exists()) await file.delete();
    final req = http.Request('GET', Uri.parse(url));
    final streamed = await http.Client()
        .send(req)
        .timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw Exception('download http ${streamed.statusCode}');
    }
    final total = streamed.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
    } finally {
      await sink.close();
    }
    return file.path;
  }

  /// 安装 APK：FileProvider 授权 + ACTION_VIEW 唤起系统安装器。
  static Future<bool> install(String path) => PermissionCenter.installApk(path);
}
