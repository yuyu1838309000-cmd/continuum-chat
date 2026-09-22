import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

/// 工具箱扩展配置（mcp / 自定义工具 / skill），读写 8816。
/// 8816 请求统一带 ChatApi.authHeaders。
class ExtensionConfigApi {
  ExtensionConfigApi._();

  static const mcpSecretConfiguredValue = '__CONTINUUM_SECRET_CONFIGURED__';
  static final RegExp _mcpSecretKeyPattern = RegExp(
    r'(authorization|api[-_ ]?key|apikey|token|secret|password|passwd|credential|private[-_ ]?key)',
    caseSensitive: false,
  );

  static Uri _url(String path) => Uri.parse(ServerConfig.url(8816, path));

  static Uri _urlWithQuery(String path, Map<String, String> query) =>
      _url(path).replace(queryParameters: query);

  static Map<String, String> _headers([bool json = false]) =>
      ChatApi.authHeaders(json ? {'Content-Type': 'application/json'} : null);

  static Future<Map<String, dynamic>?> _get(String path) async {
    return _getUri(_url(path));
  }

  static Future<Map<String, dynamic>?> _getUri(Uri uri) async {
    try {
      final resp = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final resp = await http
        .post(_url(path), headers: _headers(true), body: jsonEncode(body))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('POST $path failed: ${resp.statusCode}');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), v));
    throw const FormatException('response is not a JSON object');
  }

  static Future<Map<String, dynamic>?> _postOrNull(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await _post(path, body);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _diagnosticGet(Uri uri) async {
    try {
      final resp = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 8));
      return _diagnosticResponse(resp);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _diagnosticPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await http
          .post(_url(path), headers: _headers(true), body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));
      return _diagnosticResponse(resp);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _diagnosticResponse(http.Response resp) {
    final data = _decodeDiagnosticBody(resp.body);
    final result = <String, dynamic>{...data};
    final ok = resp.statusCode == 200 && result['ok'] != false;
    result['status'] = resp.statusCode;
    result['ok'] = ok;
    if (!ok &&
        (result['error'] == null || result['error'].toString().isEmpty)) {
      result['error'] = _diagnosticFallbackError(resp.statusCode, data);
    }
    return result;
  }

  static Map<String, dynamic> _decodeDiagnosticBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const {};
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
      return {'result': decoded.toString()};
    } catch (_) {
      return {'error': trimmed};
    }
  }

  static String _diagnosticFallbackError(
    int status,
    Map<String, dynamic> data,
  ) {
    for (final key in ['message', 'detail', 'result']) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return 'HTTP $status';
  }

  static Future<Map<String, dynamic>?> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await http
          .put(_url(path), headers: _headers(true), body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> mcp() => _get('/mcp-config');

  static bool isSecretConfigKey(String key) =>
      _mcpSecretKeyPattern.hasMatch(key);

  static bool isSecretConfiguredValue(String value) =>
      value == mcpSecretConfiguredValue;

  static Future<Map<String, dynamic>?> saveMcp(
    List<Map<String, dynamic>> servers,
  ) => _post('/mcp-config', {'servers': servers});

  static Future<Map<String, dynamic>?> plugins() => _get('/plugin-config');

  static Future<Map<String, dynamic>?> savePlugins(
    List<Map<String, dynamic>> plugins,
  ) => _post('/plugin-config', {'plugins': plugins});

  /// 插件市场清单（GET /plugin-market，含每个插件 installed 标记）。
  static Future<Map<String, dynamic>?> market({
    String query = '',
    String source = 'all',
    int page = 1,
  }) {
    return _getUri(
      _urlWithQuery('/plugin-market', {
        'q': query,
        'source': source,
        'page': page.toString(),
      }),
    );
  }

  /// 插件详情（GET /plugin-market/detail）。
  static Future<Map<String, dynamic>?> marketDetail({
    required String source,
    required String id,
  }) {
    return _getUri(
      _urlWithQuery('/plugin-market/detail', {'source': source, 'id': id}),
    );
  }

  /// 市场插件一键安装/卸载。复用 _post 拿不到非 200 的错误信息，
  /// 这里单独实现：返回体里带 ok/status/error，App 能直接提示失败原因。
  static Future<Map<String, dynamic>?> _marketAction(
    String path,
    String id,
    String source,
  ) async {
    try {
      final resp = await http
          .post(
            _url(path),
            headers: _headers(true),
            body: jsonEncode({'id': id, 'source': source}),
          )
          .timeout(const Duration(seconds: 8));
      Map<String, dynamic>? data;
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {
        // 非 JSON 响应：只带回状态码
      }
      return {
        'ok': resp.statusCode == 200,
        'status': resp.statusCode,
        ...?data,
      };
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> installMarketPlugin(
    String id, {
    String source = 'local',
  }) => _marketAction('/plugin-market/install', id, source);

  static Future<Map<String, dynamic>?> uninstallMarketPlugin(
    String id, {
    String source = 'local',
  }) => _marketAction('/plugin-market/uninstall', id, source);

  static Future<Map<String, dynamic>?> skills() => _get('/skills');

  static Future<Map<String, dynamic>?> addSkill(String name, String content) =>
      _postOrNull('/skills', {
        'action': 'add',
        'name': name,
        'content': content,
      });

  static Future<Map<String, dynamic>?> deleteSkill(String name) =>
      _postOrNull('/skills', {'action': 'delete', 'name': name});

  /// v0.2.153：skill 详情（GET /skills/{name}，含 SKILL.md 全文 + 启停状态）
  static Future<Map<String, dynamic>?> skillDetail(String name) {
    final safe = Uri.encodeComponent(name);
    return _get('/skills/$safe');
  }

  /// v0.2.153：skill 启停（PUT /skills/{name}）
  static Future<Map<String, dynamic>?> setSkillEnabled(
    String name,
    bool enabled,
  ) {
    final safe = Uri.encodeComponent(name);
    return _put('/skills/$safe', {'enabled': enabled});
  }

  /// v0.2.153：快捷消息列表（~/quick_messages.json，8816 GET /quick-messages）
  static Future<List<String>> quickMessages() async {
    final data = await _get('/quick-messages');
    final list = data?['messages'];
    if (list is List) {
      return [for (final m in list) m.toString()];
    }
    return const [];
  }

  /// v0.2.153：保存快捷消息列表（8816 POST /quick-messages，整体替换）
  static Future<List<String>?> saveQuickMessages(List<String> messages) async {
    final data = await _postOrNull('/quick-messages', {'messages': messages});
    final list = data?['messages'];
    if (list is List) {
      return [for (final m in list) m.toString()];
    }
    return null;
  }

  /// v0.2.153：工具测试（8816 POST /mcp/test，复用 remote/stdio MCP 调用，
  /// 不落库不注入对话，纯测试）
  static Future<Map<String, dynamic>?> testMcp({
    required String serverName,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) => _diagnosticPost('/mcp/test', {
    'server_name': serverName,
    'tool_name': toolName,
    'arguments': arguments,
  });

  /// 命令工具测试（POST /plugin/test）：执行 plugin_config 里的自定义命令工具。
  static Future<Map<String, dynamic>?> testCommand({
    required String name,
    required Map<String, dynamic> arguments,
  }) => _diagnosticPost('/plugin/test', {'name': name, 'arguments': arguments});

  /// 拉 MCP server 的工具名列表（GET /mcp/tools?server=…），保留后端错误文本。
  static Future<Map<String, dynamic>?> mcpToolsResult(String serverName) {
    return _diagnosticGet(_urlWithQuery('/mcp/tools', {'server': serverName}));
  }

  static Future<List<Map<String, dynamic>>?> mcpTools(String serverName) async {
    final data = await mcpToolsResult(serverName);
    if (data == null || data['ok'] != true) return null;
    final list = data['tools'];
    if (list is List) {
      return [
        for (final t in list)
          if (t is Map)
            {
              'name': t['name']?.toString() ?? '',
              'description': t['description']?.toString() ?? '',
            },
      ];
    }
    return const [];
  }
}
