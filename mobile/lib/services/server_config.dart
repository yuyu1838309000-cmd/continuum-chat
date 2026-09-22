import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 服务器地址配置（配置中心 · 服务器地址卡片）
/// - host 存 shared_preferences（key: server_host），默认 127.0.0.1
/// - App 里所有 http://127.0.0.1:端口/路径 都从这里动态拼：
///   换服务器只改这一个地方，不用重新编译
/// - ChangeNotifier：改完 host 全局通知，设置页/配置页即时刷新
class ServerConfig extends ChangeNotifier {
  ServerConfig._();
  static final ServerConfig instance = ServerConfig._();

  static const String _key = 'server_host';
  static const String defaultHost = '127.0.0.1';

  String _host = defaultHost;
  String get host => _host;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final h = prefs.getString(_key)?.trim();
    if (h != null && h.isNotEmpty) {
      _host = h;
      notifyListeners();
    }
  }

  /// 保存 host（归一化：去协议前缀、去末尾斜杠），立即生效并全局广播。
  /// 返回 false 表示输入带端口/路径，调用方应提示只填 IP 或域名。
  Future<bool> setHost(String raw) async {
    var v = raw.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    if (v.isEmpty) return false;
    Uri uri;
    try {
      uri = Uri.parse(v.contains('://') ? v : '//$v');
      if (uri.hasPort ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.host.trim().isEmpty) {
        return false;
      }
      v = uri.host.trim();
    } on FormatException {
      return false;
    }
    _host = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, v);
    return true;
  }

  static const bool _candidateRuntime = bool.fromEnvironment(
    'CONTINUUM_CANDIDATE',
    defaultValue: false,
  );

  static bool get isCandidateRuntime => _candidateRuntime;
  static int get runtimePort => _candidateRuntime ? 8815 : 8816;

  static String runtimeUrl(String path) => url(runtimePort, path);

  static int _effectivePort(int port) {
    if (!_candidateRuntime) return port;
    if (port == 8816) return runtimePort;
    return port;
  }

  /// 拼服务器 URL：http://{host}:{port}{path}。候选验收包只重定向 Runtime/Memory。
  static String url(int port, String path) {
    final effectivePort = _effectivePort(port);
    return 'http://${instance._host}:$effectivePort$path';
  }
}
