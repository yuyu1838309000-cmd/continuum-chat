import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

/// 一条 Termux 命令的执行结果（App 侧本地执行后回传 8816 用）。
class TermuxCommandResult {
  final String command;
  final bool ok;
  final String output;

  const TermuxCommandResult({
    required this.command,
    required this.ok,
    required this.output,
  });

  Map<String, dynamic> toJson() => {
    'command': command,
    'ok': ok,
    'output': output,
  };
}

enum CanonicalReportStatus { accepted, closed, retryable, rejected }

class CanonicalToolIdentity {
  const CanonicalToolIdentity({
    required this.generationId,
    required this.toolCallId,
  });

  final String generationId;
  final String toolCallId;

  @override
  bool operator ==(Object other) =>
      other is CanonicalToolIdentity &&
      other.generationId == generationId &&
      other.toolCallId == toolCallId;

  @override
  int get hashCode => Object.hash(generationId, toolCallId);
}

class CanonicalReportResult {
  const CanonicalReportResult({required this.status, required this.identities});

  final CanonicalReportStatus status;
  final Set<CanonicalToolIdentity> identities;
}

/// Termux MCP 桥接（v0.2.153）：
/// Termux MCP 跑在手机本机 127.0.0.1:8808（RikkaHub 本机直连同款），服务器够不到
/// 手机，必须由Continuum Chat App 本地执行。链路：8816 SSE 推 termux_pending → App 这里调
/// http://127.0.0.1:8808/mcp 的 tools/call（name=shell, arguments={"command": ...}）
/// → 拿到结果 → POST 8816 /tool-result 回传，8816 用结果继续生成最终回复。
/// FastMCP streamable HTTP：先 initialize 拿 mcp-session-id，再 tools/call；
/// 响应可能是纯 JSON 或 SSE（event: message\n data: {...}），两种都解析。
class TermuxApi {
  static const String mcpUrl = 'http://127.0.0.1:8808/mcp';
  static const Duration mcpTimeout = Duration(seconds: 20);

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
  };

  /// 执行单条命令（超时 20s）。失败不抛异常：返回 ok=false + 中文说明，
  /// 方便调用方直接把失败原因回传给 8816（"Termux 没开，AI 助手够不到手机"）。
  static Future<TermuxCommandResult> runCommand(String command) async {
    final client = http.Client();
    try {
      String? sessionId;
      try {
        sessionId = await _initialize(client);
      } catch (_) {
        sessionId = null;
      }
      // 按约定先发 {"command": ...}；个别 Termux MCP 实现参数名是 cmd，
      // 结果明显缺 cmd 参数时自动换 cmd 重试一次（真机正常只走第一种）。
      var result = await _toolsCall(client, sessionId, {'command': command});
      if (!result.ok && result.text.contains('cmd')) {
        result = await _toolsCall(client, sessionId, {'cmd': command});
      }
      return TermuxCommandResult(
        command: command,
        ok: result.ok,
        output: result.text,
      );
    } catch (e) {
      return TermuxCommandResult(
        command: command,
        ok: false,
        output: 'Termux 连不上（127.0.0.1:8808）：$e',
      );
    } finally {
      client.close();
    }
  }

  /// 把一组执行结果回传 8816（POST /tool-result，带 X-Token）。
  static Future<bool> reportResult(
    String chatId,
    int round,
    List<TermuxCommandResult> results,
  ) => reportResults(chatId, round, [for (final r in results) r.toJson()]);

  /// 通用结果回传（Termux 与手机工具共用 POST /tool-result）。
  /// results 每项 {command/tool, ok, output}，8816 按 pending 类型格式化注入。
  static Future<bool> reportResults(
    String chatId,
    int round,
    List<Map<String, dynamic>> results,
  ) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/tool-result')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'chat_id': chatId,
              'round': round,
              'results': results,
            }),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Runtime canonical device result reporter. Each result belongs to one
  /// normalized provider tool call and keeps that identity end-to-end.
  static Future<CanonicalReportResult> reportCanonicalResults(
    String generationId,
    List<Map<String, dynamic>> results,
  ) async {
    final cleanGenerationId = generationId.trim();
    final requested = <CanonicalToolIdentity>{
      for (final result in results)
        if ((result['tool_call_id']?.toString() ?? '').trim().isNotEmpty)
          CanonicalToolIdentity(
            generationId: cleanGenerationId,
            toolCallId: result['tool_call_id'].toString().trim(),
          ),
    };
    if (cleanGenerationId.isEmpty ||
        results.isEmpty ||
        requested.length != results.length) {
      return CanonicalReportResult(
        status: CanonicalReportStatus.rejected,
        identities: requested,
      );
    }
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.runtimeUrl('/tool-result')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'generation_id': cleanGenerationId,
              'results': results,
            }),
          )
          .timeout(const Duration(seconds: 8));
      final status = resp.statusCode;
      if (status == 200) {
        final body = _jsonMap(resp.body);
        final accepted = _identitySet(body?['accepted']);
        if (body?['ok'] == true &&
            accepted != null &&
            accepted.length == requested.length &&
            accepted.every(requested.contains)) {
          return CanonicalReportResult(
            status: CanonicalReportStatus.accepted,
            identities: accepted,
          );
        }
        return CanonicalReportResult(
          status: CanonicalReportStatus.rejected,
          identities: requested,
        );
      }
      if (status == 410) {
        final identity = _identityFromMap(_jsonMap(resp.body));
        if (identity != null && requested.contains(identity)) {
          return CanonicalReportResult(
            status: CanonicalReportStatus.closed,
            identities: {identity},
          );
        }
        return CanonicalReportResult(
          status: CanonicalReportStatus.rejected,
          identities: requested,
        );
      }
      if (status == 408 || status == 425 || status == 429 || status >= 500) {
        return CanonicalReportResult(
          status: CanonicalReportStatus.retryable,
          identities: requested,
        );
      }
      return CanonicalReportResult(
        status: CanonicalReportStatus.rejected,
        identities: requested,
      );
    } catch (_) {
      return CanonicalReportResult(
        status: CanonicalReportStatus.retryable,
        identities: requested,
      );
    }
  }

  static Map<String, dynamic>? _jsonMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static CanonicalToolIdentity? _identityFromMap(Object? raw) {
    if (raw is! Map) return null;
    final generationId = (raw['generation_id']?.toString() ?? '').trim();
    final toolCallId = (raw['tool_call_id']?.toString() ?? '').trim();
    if (generationId.isEmpty || toolCallId.isEmpty) return null;
    return CanonicalToolIdentity(
      generationId: generationId,
      toolCallId: toolCallId,
    );
  }

  static Set<CanonicalToolIdentity>? _identitySet(Object? raw) {
    if (raw is! List) return null;
    final identities = <CanonicalToolIdentity>{};
    for (final item in raw) {
      final identity = _identityFromMap(item);
      if (identity == null || !identities.add(identity)) return null;
    }
    return identities;
  }

  /// v0.2.163：主动消息（心跳）带 tools 时，App 静默执行完按 msg_id 回传，
  /// 8816 用结果生成一句自然追加回复入队 /pending。失败不重试、不阻塞。
  static Future<bool> reportResultsByMsgId(
    String msgId,
    List<Map<String, dynamic>> results,
  ) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/tool-result')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'msg_id': msgId, 'results': results}),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _initialize(http.Client client) async {
    final resp = await client
        .post(
          Uri.parse(mcpUrl),
          headers: _jsonHeaders,
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2025-03-26',
              'capabilities': {},
              'clientInfo': {'name': 'continuum', 'version': '1.0'},
            },
          }),
        )
        .timeout(mcpTimeout);
    return resp.headers['mcp-session-id'];
  }

  static Future<({bool ok, String text})> _toolsCall(
    http.Client client,
    String? sessionId,
    Map<String, dynamic> arguments,
  ) async {
    final headers = <String, String>{..._jsonHeaders};
    if (sessionId != null && sessionId.isNotEmpty) {
      headers['Mcp-Session-Id'] = sessionId;
    }
    final resp = await client
        .post(
          Uri.parse(mcpUrl),
          headers: headers,
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': 'shell', 'arguments': arguments},
          }),
        )
        .timeout(mcpTimeout);
    if (resp.statusCode != 200) {
      return (ok: false, text: 'MCP 返回 ${resp.statusCode}');
    }
    final body = utf8.decode(resp.bodyBytes);
    final contentType = resp.headers['content-type'] ?? '';
    final text = contentType.contains('text/event-stream')
        ? _parseSse(body)
        : body;
    return _parseJsonRpc(text);
  }

  /// 从 SSE 文本里抽出所有 data: 行（JSON-RPC 消息），取最后一个。
  static String _parseSse(String body) {
    final lines = body.split('\n');
    String last = '';
    for (final line in lines) {
      if (line.startsWith('data:')) {
        last = line.substring(5).trim();
      }
    }
    return last;
  }

  /// 解析 JSON-RPC 响应：result.content[].text 拼接 / result.text / error。
  static ({bool ok, String text}) _parseJsonRpc(String raw) {
    dynamic obj;
    try {
      obj = jsonDecode(raw);
    } catch (_) {
      return (ok: false, text: raw.length > 500 ? raw.substring(0, 500) : raw);
    }
    if (obj is! Map) {
      return (ok: false, text: raw.length > 500 ? raw.substring(0, 500) : raw);
    }
    final error = obj['error'];
    if (error != null) {
      return (ok: false, text: 'MCP 错误：$error');
    }
    final result = obj['result'];
    if (result is Map) {
      if (result['isError'] == true) {
        return (ok: false, text: _contentText(result));
      }
      return (ok: true, text: _contentText(result));
    }
    return (ok: false, text: raw.length > 500 ? raw.substring(0, 500) : raw);
  }

  static String _contentText(Map<dynamic, dynamic> result) {
    final parts = <String>[];
    final content = result['content'];
    if (content is List) {
      for (final c in content) {
        if (c is Map && c['type'] == 'text' && c['text'] is String) {
          parts.add(c['text'] as String);
        }
      }
    }
    if (parts.isNotEmpty) return parts.join('\n');
    final text = result['text'];
    if (text is String && text.isNotEmpty) return text;
    return jsonEncode(result);
  }
}
