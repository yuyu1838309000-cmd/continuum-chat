import 'package:shared_preferences/shared_preferences.dart';

class ServerConfig {
  const ServerConfig({
    this.scheme = 'http',
    this.host = '10.0.2.2',
    this.runtimePort = 8816,
    this.memoryPort = 8820,
    this.token = '',
  });

  static const _schemeKey = 'server.scheme';
  static const _hostKey = 'server.host';
  static const _runtimePortKey = 'server.runtimePort';
  static const _memoryPortKey = 'server.memoryPort';
  static const _tokenKey = 'server.token';

  final String scheme;
  final String host;
  final int runtimePort;
  final int memoryPort;
  final String token;

  Uri runtimeUri(String path, [Map<String, dynamic>? query]) =>
      _uri(runtimePort, path, query);

  Uri memoryUri(String path, [Map<String, dynamic>? query]) =>
      _uri(memoryPort, path, query);

  Uri _uri(int port, String path, Map<String, dynamic>? query) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: normalizedPath,
      queryParameters: query?.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
    );
  }

  String? validate() {
    if (scheme != 'http' && scheme != 'https') {
      return 'Scheme must be http or https.';
    }
    if (host.trim().isEmpty ||
        host.contains('://') ||
        host.contains('/') ||
        host.contains(RegExp(r'\s'))) {
      return 'Enter a host name or IP address without a path.';
    }
    if (!_validPort(runtimePort) || !_validPort(memoryPort)) {
      return 'Ports must be between 1 and 65535.';
    }
    return null;
  }

  static bool _validPort(int port) => port >= 1 && port <= 65535;

  Future<void> save(SharedPreferences preferences) async {
    final error = validate();
    if (error != null) throw FormatException(error);
    await Future.wait([
      preferences.setString(_schemeKey, scheme),
      preferences.setString(_hostKey, host),
      preferences.setInt(_runtimePortKey, runtimePort),
      preferences.setInt(_memoryPortKey, memoryPort),
      preferences.setString(_tokenKey, token),
    ]);
  }

  static Future<ServerConfig> load(SharedPreferences preferences) async =>
      ServerConfig(
        scheme: preferences.getString(_schemeKey) ?? 'http',
        host: preferences.getString(_hostKey) ?? '10.0.2.2',
        runtimePort: preferences.getInt(_runtimePortKey) ?? 8816,
        memoryPort: preferences.getInt(_memoryPortKey) ?? 8820,
        token: preferences.getString(_tokenKey) ?? '',
      );
}
