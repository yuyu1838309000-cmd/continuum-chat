import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import 'server_config.dart';

enum SceneMode {
  unknown('unknown'),
  online('online'),
  faceToFace('face_to_face');

  const SceneMode(this.wireValue);

  final String wireValue;

  static SceneMode? tryParse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final mode in values) {
      if (mode.wireValue == normalized) return mode;
    }
    return null;
  }
}

/// 对话走服务器 8816 /chat（v0.2.108 搬家第3步）：App 只传过滤 activity 后的原始
/// messages，系统提示/记忆/时间注入由 8816 服务端统一拼装（拼系统提示+记忆+时间感知），
/// SSE 流式回（content/reasoning_content/usage 全透传）。
/// 发送的 user 消息与流式回复由 8816 记 raw_events（App 不再 /ingest，避免双记）。
/// v0.2.109 起模型配置归服务器 8816（~/model_config.json）：配置中心模型卡片
/// GET/POST /model-config 读写它，/chat 调 DeepSeek 的 base_url/model/api_key/
/// 参数全从服务器配置来（App 不再透传模型参数覆盖）。
/// v0.2.115 起 App 不再直连 DeepSeek：fetchBalance 走 8816 /balance，
/// sendConclusion 走 8816 /chat（系统提示/记忆/时间注入由服务端统一拼装），
/// 内置 DeepSeek key 已移除（模型 key 一律由服务器 ~/model_config.json 管理）。
/// [shell] 标记剥离器（v0.2.114）：跨分片安全的状态机，兼容
/// [shell]...[/shell] 与 [shell: 命令] 两种变体；只开不闭连同其后内容剥掉。
/// v0.2.115 起 send() 与 sendConclusion() 共用同一套剥离逻辑。
class ShellTagStripper {
  ShellTagStripper();

  final RegExp _shellColonRe = RegExp(r'\[shell\s*[:：]');
  var _buf = '';
  var _mode = 0; // 0=普通, 1=[shell]...[/shell] 内, 2=[shell:...] 内

  /// 处理一个流式分片，返回剥掉 [shell] 标记及命令内容后的文本。
  String process(String chunk) {
    const open = '[shell]';
    const close = '[/shell]';
    _buf += chunk;
    final out = StringBuffer();
    while (_buf.isNotEmpty) {
      if (_mode == 1) {
        final idx = _buf.indexOf(close);
        if (idx < 0) {
          if (_buf.length > close.length - 1) {
            _buf = _buf.substring(_buf.length - (close.length - 1));
          }
          break;
        }
        _buf = _buf.substring(idx + close.length);
        _mode = 0;
      } else if (_mode == 2) {
        final idx = _buf.indexOf(']');
        if (idx < 0) break;
        _buf = _buf.substring(idx + 1);
        _mode = 0;
      } else {
        final oi = _buf.indexOf(open);
        final ci = _buf.indexOf(close);
        final col = _shellColonRe.firstMatch(_buf);
        final n = _buf.length;
        if (oi < 0 && ci < 0 && col == null) {
          var keep = 0;
          for (var k = close.length - 1; k > 0; k--) {
            if (_buf.endsWith(close.substring(0, k))) {
              keep = k;
              break;
            }
          }
          for (var k = open.length - 1; k > 0; k--) {
            if (_buf.endsWith(open.substring(0, k))) {
              if (k > keep) keep = k;
              break;
            }
          }
          final emitEnd = _buf.length - keep;
          out.write(_buf.substring(0, emitEnd));
          _buf = _buf.substring(emitEnd);
          break;
        }
        final ciAt = ci >= 0 ? ci : n + 1;
        final oiAt = oi >= 0 ? oi : n + 1;
        final coAt = col != null ? col.start : n + 1;
        if (ciAt < oiAt && ciAt < coAt) {
          out.write(_buf.substring(0, ciAt));
          _buf = _buf.substring(ciAt + close.length);
          continue;
        }
        if (oiAt <= coAt) {
          out.write(_buf.substring(0, oiAt));
          _buf = _buf.substring(oiAt + open.length);
          _mode = 1;
        } else {
          out.write(_buf.substring(0, coAt));
          _buf = _buf.substring(col!.end);
          _mode = 2;
        }
      }
    }
    return out.toString();
  }
}

class ChatApi {
  /// 当前主链路流式请求的 http.Client（v0.2.161 停止生成用）。
  /// 点叉中断时 close() 会让 send() 里的流抛异常 → onError 兜底，
  /// 聊天页靠「reply 已不是 _activeReply」判断忽略这次报错。
  static http.Client? _activeSendClient;

  /// 中断当前正在进行的 send() 流式请求（停止生成）。
  static void cancelActiveSend() {
    final client = _activeSendClient;
    _activeSendClient = null;
    client?.close();
  }

  static const String defaultBaseUrl = 'https://api.deepseek.com/v1';
  static const String defaultModel = 'deepseek-v4-flash';
  // 多供应商默认值（v0.2.156）：Gemini 走 Google 官方 OpenAI 兼容端点
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';
  static const String geminiDefaultModel = 'gemini-2.5-flash';
  static const String openRouterBaseUrl = 'https://openrouter.ai/api/v1';

  /// Optional runtime token supplied at build time with
  /// `--dart-define=CONTINUUM_SERVER_TOKEN=...`.
  ///
  /// Local development servers can leave it unset. Remote deployments should
  /// inject their own value rather than storing credentials in source control.
  static const String serverToken = String.fromEnvironment(
    'CONTINUUM_SERVER_TOKEN',
  );

  /// Runtime request headers. The token header is omitted when no token was
  /// configured, which keeps the loopback development default credential-free.
  static Map<String, String> authHeaders([Map<String, String>? extra]) => {
    ...?extra,
    if (serverToken.isNotEmpty) 'X-Token': serverToken,
  };
  static String get chatUrl => ServerConfig.url(8816, '/chat');
  static String get ingestUrl => ServerConfig.url(8816, '/ingest');

  /// 读取当前人工选择的相处模式。`null` 只表示请求失败或响应无效，
  /// 服务端明确返回 `unknown` 时保留为 [SceneMode.unknown]。
  static Future<SceneMode?> fetchSceneMode() async {
    try {
      final resp = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/scene-mode')),
            headers: authHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      return SceneMode.tryParse(decoded['mode'] ?? decoded['scene_mode']);
    } catch (_) {
      return null;
    }
  }

  /// 写入人工选择的相处模式。成功返回服务端确认的模式，失败返回 `null`。
  static Future<SceneMode?> saveSceneMode(SceneMode mode) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/scene-mode')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'mode': mode.wireValue}),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      return SceneMode.tryParse(decoded['mode'] ?? decoded['scene_mode']);
    } catch (_) {
      return null;
    }
  }

  // 模型配置 key（shared_preferences 本地兜底；v0.2.109 起生效源是服务器 ~/model_config.json，
  // 模型配置页加载时从 8816 拉、保存时写 8816，本地这份用于"服务器拉不到"时兜底）
  static const String cfgKeyBaseUrl = 'model_base_url';
  static const String cfgKeyTemperature = 'model_temperature';
  static const String cfgKeyTopP = 'model_top_p';
  static const String cfgKeyMaxTokens = 'model_max_tokens';
  static const String cfgKeyModel = 'model_name';
  static const String cfgKeyApiKey = 'model_api_key';
  static const String cfgKeyThinking = 'model_thinking';
  static const String cfgKeyReasoningEffort = 'model_reasoning_effort';
  // 搜索设置 key（配置中心 · 搜索卡片）：每次搜几条结果（默认 5，范围 1-10）
  static const String cfgKeySearchResults = 'search_max_results';

  /// 读取模型配置（本地兜底）。max_tokens 可空（空则不传给 API）；apiKey 配了就用自己的，
  /// 空用内置；baseUrl 配了用自己的，空用默认 https://api.deepseek.com/v1。
  static Future<Map<String, dynamic>> loadModelConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'baseUrl': prefs.getString(cfgKeyBaseUrl) ?? defaultBaseUrl,
      'model': prefs.getString(cfgKeyModel) ?? defaultModel,
      'temperature': prefs.getDouble(cfgKeyTemperature) ?? 1.0,
      'top_p': prefs.getDouble(cfgKeyTopP) ?? 1.0,
      'max_tokens': prefs.getInt(cfgKeyMaxTokens),
      'apiKey': prefs.getString(cfgKeyApiKey) ?? '',
      // 思考模式：默认开（推理模型带 reasoning_content），关掉响应更快
      'thinking': prefs.getBool(cfgKeyThinking) ?? true,
      // 思考档位：off/low/high/xhigh/max，默认 high
      'reasoningEffort': prefs.getString(cfgKeyReasoningEffort) ?? 'high',
    };
  }

  /// 组装 thinking 参数：思考关闭或档位 off 给 disabled，
  /// 其余档位给 enabled + reasoning_effort（DeepSeek V4）。
  static Map<String, dynamic> _thinkingParam(Map<String, dynamic> cfg) {
    if (cfg['thinking'] == false) {
      return {'type': 'disabled'};
    }
    final effort = _normalizeReasoningEffort(cfg['reasoningEffort']);
    if (effort == 'off') {
      return {'type': 'disabled'};
    }
    return {'type': 'enabled', 'reasoning_effort': effort};
  }

  /// 归一化思考档位；非法值回 high。避免 App 兜底数据异常时传非法参数。
  static String _normalizeReasoningEffort(Object? value) {
    const efforts = {'off', 'low', 'high', 'xhigh', 'max'};
    final s = (value ?? '').toString().trim().toLowerCase();
    return efforts.contains(s) ? s : 'high';
  }

  static int? _jsonInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static ({int? userRawEventId, int? assistantRawEventId})
  _rawEventIdsFromMetadata(Map<String, dynamic> json) => (
    userRawEventId: _jsonInt(json['user_raw_event_id']),
    assistantRawEventId: _jsonInt(json['assistant_raw_event_id']),
  );

  @visibleForTesting
  static ({int? userRawEventId, int? assistantRawEventId})
  rawEventIdsFromMetadataForTesting(Map<String, dynamic> json) =>
      _rawEventIdsFromMetadata(json);

  /// 查 DeepSeek 账户余额（v0.2.115 起走服务器 8816 /balance，不再直连 DeepSeek；
  /// 服务器读 ~/model_config.json 的 key 查 /user/balance 后回传）。
  /// 返回 {available, totalBalance, currency}，失败返回 null。
  static Future<Map<String, dynamic>?> fetchBalance() async {
    try {
      final resp = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/balance')),
            headers: authHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (json == null || json['ok'] != true) return null;
      final balance = json['balance'] as Map<String, dynamic>?;
      if (balance == null) return null;
      final infos = balance['balance_infos'] as List<dynamic>?;
      if (infos == null || infos.isEmpty) return null;
      final first = infos.first as Map<String, dynamic>;
      return {
        'available': balance['is_available'] ?? false,
        'totalBalance': (first['total_balance'] as String? ?? '0'),
        'currency': (first['currency'] as String? ?? 'CNY'),
      };
    } catch (_) {
      return null;
    }
  }

  /// 读服务器「允许AI 助手主动找我」总开关（GET 8816 /status 的 allow_proactive）。
  /// 服务器可达时以它为准覆盖本地默认（审计报告 🟡#3）；失败返回 null（离线兜底）。
  static Future<bool?> fetchAllowProactive() async {
    try {
      final resp = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/status')),
            headers: authHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      final v = j?['allow_proactive'];
      return v is bool ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 确认消费一批 /pending 消息（POST 8816 /pending/ack，审计报告 🟡#5）。
  /// 老服务端无此路由返回 404：静默忽略，行为退回「取即清空」。
  static Future<void> ackPending(List<String> ids) async {
    final clean = [for (final id in ids) id]..removeWhere((id) => id.isEmpty);
    if (clean.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/pending/ack')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'ids': clean}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // ack 失败不重试：服务器宽限期后会重新投递，宁可多投不可丢
    }
  }

  /// 从 8816 拉模型配置（GET /model-config，v0.2.109 起配置中心模型卡片管服务器 8816 的模型）。
  /// 返回服务器 ~/model_config.json 的配置（api_key 已脱敏，只用于显示），失败返回 null。
  static Future<Map<String, dynamic>?> fetchModelConfig() async {
    try {
      final resp = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/model-config')),
            headers: authHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null) return null;
      return j;
    } catch (_) {
      // 网络/超时失败返回 null，页面兜底用本地 shared_preferences
      return null;
    }
  }

  /// 保存模型配置到 8816（POST /model-config，v0.2.156 多供应商）。
  /// [providerId] 供应商 id；[fields] 只带要改的字段（api_key 缺省 = 服务器保留原值）；
  /// [active] 非空时同时切换启用；[deleteProvider] 删除/清空该供应商。
  /// 成功返回脱敏后的整份公开配置；失败抛带中文提示的异常。
  static Future<Map<String, dynamic>> saveProviderConfig(
    String providerId,
    Map<String, dynamic> fields, {
    String? active,
    bool deleteProvider = false,
  }) async {
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/model-config')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'provider': providerId,
              ...fields,
              'active': ?active,
              if (deleteProvider) 'delete': true,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw Exception('连不上服务器，配置没保存');
    }
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      j = null;
    }
    if (resp.statusCode != 200 || j == null) {
      throw Exception((j?['error'] as String?) ?? '保存失败（${resp.statusCode}）');
    }
    return (j['config'] as Map<String, dynamic>?) ?? j;
  }

  /// 测试连接（v0.2.158）：POST 8816 /test-connection，用表单当前值
  /// （未保存也生效）发一条最小请求，验证 key/模型可用。
  /// 返回 {ok, status, latency_ms, model, snippet|error}，网络失败返回 null。
  static Future<Map<String, dynamic>?> testConnection(
    String providerId,
    Map<String, dynamic> config,
  ) async {
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/test-connection')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'provider': providerId, 'config': config}),
          )
          .timeout(const Duration(seconds: 90));
    } catch (_) {
      return null;
    }
    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (resp.statusCode != 200) return null;
      return j;
    } catch (_) {
      return null;
    }
  }

  /// 实时发现供应商可用模型：POST 8816 /models/discover。
  ///
  /// [config] 使用表单当前未保存字段；api_key 缺省时由服务器复用已存 key。
  /// 此请求只读，不保存配置。网络、超时或非 JSON 响应返回 null；服务器返回的
  /// `{ok: false, error: ...}` 原样交给页面展示轻量错误。
  static Future<Map<String, dynamic>?> discoverModels(
    String providerId,
    Map<String, dynamic> config,
  ) async {
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/models/discover')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'provider': providerId, 'config': config}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return null;
    }
    try {
      return jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// 文生图（阶段四）：调服务器 8816 /gen_image 生成图片（硅基流动 FLUX 1.1 Pro）。
  /// [prompt] 画图描述；[size] 可选尺寸（如 1024x1024）。
  /// 返回生成图的服务器可访问 URL，失败返回 null（不抛异常，静默兜底）。
  static Future<String?> genImage(String prompt, {String? size}) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/gen_image')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'prompt': prompt,
              if (size != null && size.isNotEmpty) 'size': size,
            }),
          )
          .timeout(const Duration(seconds: 180));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final url = j['url'] as String?;
        if (url != null && url.isNotEmpty) return url;
      }
    } catch (_) {
      // 网络/超时失败静默，调用方兜底
    }
    return null;
  }

  /// 读搜索设置（配置中心 · 搜索卡片）：每次搜几条结果，默认 5，范围 1-10。
  static Future<int> loadSearchConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(cfgKeySearchResults) ?? 5).clamp(1, 10);
  }

  /// 网页搜索（面板工具第二批）：调服务器 8816 /tools/run web（Tavily）。
  /// [query] 搜索关键词；[maxResults] 结果条数（1-10），不传用配置中心默认。
  /// 返回 [{title, url, content}]，失败/超时返回 null（不抛异常，静默兜底不卡聊天）。
  static Future<List<Map<String, dynamic>>?> searchWeb(
    String query, {
    int? maxResults,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/tools/run')),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'tool_id': 'web',
              'params': {'query': query, 'max_results': ?maxResults},
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null || j['ok'] != true) return null;
      final results = j['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;
      return [
        for (final r in results)
          if (r is Map<String, dynamic>) r,
      ];
    } catch (_) {
      // 网络/超时失败静默，调用方兜底
      return null;
    }
  }

  /// 按 id 列表软删服务器 raw_events（只限 source=app，RikkaHub 的 gateway 不碰）。
  /// 软删后数据保留 7 天可恢复。返回软删条数，失败返回 null。
  static Future<int?> deleteIngested(List<int> ids) async {
    if (ids.isEmpty) return 0;
    try {
      final resp = await http
          .delete(
            Uri.parse(ingestUrl),
            headers: authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'ids': ids}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      return json?['soft_deleted'] as int?;
    } catch (_) {
      return null;
    }
  }

  /// 把一条消息转成 8816 /chat 的 API 形态：图片/文件消息重新拼接模型侧标注
  /// （多图合并 + 各图 OCR / 单图 OCR / 文件内容），主聊天链路与搜索结论链路共用，
  /// 保证模型都能"看到"附件内容。调用方需先过滤 activity 消息。
  static Map<String, dynamic> _toApiMessage(ChatMessage m) {
    if (m.role != 'user') return m.toApi();
    // 多选发图：合并成一次"发了 N 张图 + 各图 OCR"，模型一次看到全部，回一条
    if (m.imageUrls.isNotEmpty) {
      final lines = <String>[m.content];
      lines.add('[我发了 ${m.imageUrls.length} 张图：]');
      for (var i = 0; i < m.imageUrls.length; i++) {
        lines.add('图${i + 1}：${m.imageUrls[i]}');
        final ocr = i < m.imageOcrTexts.length ? m.imageOcrTexts[i] : '';
        if (ocr.isNotEmpty) lines.add('图片内容：$ocr');
      }
      return _userApiMessage(m, lines.join('\n'));
    }
    if (m.ocrText != null &&
        m.ocrText!.isNotEmpty &&
        m.imageUrl != null &&
        m.imageUrl!.isNotEmpty) {
      return _userApiMessage(
        m,
        '${m.content}\n[我发了一张图：${m.imageUrl}] 图片内容：${m.ocrText}',
      );
    }
    // 文件消息：模型看"文件名 + URL + 提取文本"（气泡只显示文件卡片）
    if (m.fileUrl != null && m.fileUrl!.isNotEmpty) {
      final lines = <String>[m.content];
      lines.add('[我发了一个文件：${m.fileName ?? '文件'}（${m.fileUrl}）]');
      if (m.fileExtractedText != null && m.fileExtractedText!.isNotEmpty) {
        lines.add('文件内容：${m.fileExtractedText}');
      }
      return _userApiMessage(m, lines.join('\n'));
    }
    return _userApiMessage(m, m.content);
  }

  static Map<String, dynamic> _userApiMessage(ChatMessage m, String content) {
    final attachments = _runtimeAttachments(m);
    final clientFields = _runtimeClientFields(m);
    return {
      'role': 'user',
      'content': content,
      'authored_text': m.content,
      if (attachments.isNotEmpty) 'attachments': attachments,
      if (clientFields.isNotEmpty) 'client_fields': clientFields,
      if (m.rawEventId != null) 'raw_event_id': m.rawEventId,
      if (m.eventId != null && m.eventId!.isNotEmpty) 'event_id': m.eventId,
      if (m.clientEventId != null && m.clientEventId!.isNotEmpty)
        'client_event_id': m.clientEventId,
      if (m.generationId != null && m.generationId!.isNotEmpty)
        'generation_id': m.generationId,
      if (m.epochId != null && m.epochId!.isNotEmpty) 'epoch_id': m.epochId,
    };
  }

  static List<Map<String, dynamic>> _runtimeAttachments(ChatMessage message) {
    final result = <Map<String, dynamic>>[];
    final imageUrls = message.imageUrls.isNotEmpty
        ? message.imageUrls
        : ((message.imageUrl ?? '').isNotEmpty
              ? [message.imageUrl!]
              : const <String>[]);
    for (final url in imageUrls) {
      if (url.isNotEmpty) result.add({'kind': 'image', 'resource_url': url});
    }
    if ((message.fileUrl ?? '').isNotEmpty) {
      result.add({
        'kind': 'file',
        'resource_url': message.fileUrl,
        if ((message.fileName ?? '').isNotEmpty) 'name': message.fileName,
        if (message.fileSize != null) 'size': message.fileSize,
        if ((message.fileType ?? '').isNotEmpty) 'media_type': message.fileType,
      });
    }
    return result;
  }

  static Map<String, dynamic> _runtimeClientFields(ChatMessage message) => {
    if ((message.ocrText ?? '').isNotEmpty) 'ocr_text': message.ocrText,
    if (message.imageOcrTexts.isNotEmpty)
      'image_ocr_texts': List<String>.from(message.imageOcrTexts),
    if ((message.fileExtractedText ?? '').isNotEmpty)
      'file_extracted_text': message.fileExtractedText,
  };

  /// Provider-neutral content representation used when a canonical user event is
  /// edited on the server. It mirrors normal /chat attachment expansion while
  /// keeping the locally visible authored text unchanged.
  static String runtimeMutationContent(ChatMessage message) =>
      (_toApiMessage(message)['content'] ?? message.content).toString();

  @visibleForTesting
  static Map<String, dynamic> toApiMessageForTesting(ChatMessage m) =>
      _toApiMessage(m);

  static Future<Map<String, dynamic>> buildChatRequestBody(
    List<ChatMessage> history,
  ) async {
    final cfg = await loadModelConfig();
    ChatMessage? lastUser;
    String? contextEpochId;
    var hasCanonicalAnchor = false;
    for (final message in history.reversed) {
      final epochId = (message.epochId ?? '').trim();
      final eventId = (message.eventId ?? '').trim();
      if (contextEpochId == null && epochId.isNotEmpty) {
        contextEpochId = epochId;
      }
      if (!hasCanonicalAnchor && epochId.isNotEmpty && eventId.isNotEmpty) {
        hasCanonicalAnchor = true;
      }
      if (lastUser == null && message.role == 'user' && !message.isActivity) {
        lastUser = message;
      }
      if (lastUser != null && contextEpochId != null && hasCanonicalAnchor) {
        break;
      }
    }

    // Once canonical server history is established, /chat only needs the new
    // user command. Re-uploading the whole local transcript every turn makes
    // mobile POSTs grow forever even though the server ignores the old rows.
    // Keep the full-history shape only for legacy/bootstrap conversations that
    // do not yet have a canonical event+epoch anchor.
    final requestMessages = hasCanonicalAnchor && lastUser != null
        ? <ChatMessage>[lastUser]
        : history.where((message) => !message.isActivity).toList();
    final messages = requestMessages.map(_toApiMessage).toList();

    return {
      'messages': messages,
      if ((lastUser?.clientEventId ?? '').isNotEmpty)
        'client_event_id': lastUser!.clientEventId,
      if ((lastUser?.generationId ?? '').isNotEmpty) ...{
        'generation_id': lastUser!.generationId,
        'request_id': lastUser.generationId,
      },
      if ((contextEpochId ?? '').isNotEmpty) 'context_epoch_id': contextEpochId,
      'model': cfg['model'],
      'temperature': cfg['temperature'],
      'top_p': cfg['top_p'],
      if (cfg['max_tokens'] != null) 'max_tokens': cfg['max_tokens'],
      'thinking': _thinkingParam(cfg),
    };
  }

  @visibleForTesting
  static Future<Map<String, dynamic>> chatRequestBodyForTesting(
    List<ChatMessage> history,
  ) => buildChatRequestBody(history);

  static Future<Map<String, dynamic>?> rolloverRuntimeEpoch({
    required String epochId,
    String threadId = 'main',
    String? archiveFolderId,
  }) => _runtimeJsonRequest('POST', '/runtime/epochs/rollover', {
    'thread_id': threadId,
    'epoch_id': epochId,
    if (archiveFolderId != null && archiveFolderId.isNotEmpty)
      'archive_folder_id': archiveFolderId,
  }, transportAttempts: 2);

  static Future<Map<String, dynamic>?> editRuntimeEvent({
    required String eventId,
    required String epochId,
    required String generationId,
    required String clientEventId,
    required String content,
    String threadId = 'main',
    String? requestId,
    int? rawEventId,
    List<ChatMessagePart>? parts,
  }) => _runtimeJsonRequest(
    'POST',
    '/runtime/events/${Uri.encodeComponent(eventId)}/edit',
    {
      'thread_id': threadId,
      'epoch_id': epochId,
      'generation_id': generationId,
      'client_event_id': clientEventId,
      'content': content,
      if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
      'raw_event_id': ?rawEventId,
      if (parts != null) 'parts': parts.map((e) => e.toJson()).toList(),
    },
    transportAttempts: 2,
  );

  static Future<Map<String, dynamic>?> regenerateRuntimeEvent({
    required String userEventId,
    required String epochId,
    required String generationId,
    String threadId = 'main',
  }) => _runtimeJsonRequest(
    'POST',
    '/runtime/events/${Uri.encodeComponent(userEventId)}/regenerate',
    {'thread_id': threadId, 'epoch_id': epochId, 'generation_id': generationId},
    transportAttempts: 2,
  );

  static Future<Map<String, dynamic>?> deleteRuntimeEvent({
    required String eventId,
    required String epochId,
    String threadId = 'main',
  }) => _runtimeJsonRequest(
    'DELETE',
    '/runtime/events/${Uri.encodeComponent(eventId)}',
    {'thread_id': threadId, 'epoch_id': epochId},
    transportAttempts: 2,
  );

  static Future<Map<String, dynamic>?> _runtimeJsonRequest(
    String method,
    String path,
    Map<String, dynamic> body, {
    int transportAttempts = 1,
  }) async {
    final attempts = transportAttempts < 1 ? 1 : transportAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final client = http.Client();
      try {
        final request =
            http.Request(method, Uri.parse(ServerConfig.url(8816, path)))
              ..headers.addAll(
                authHeaders({'Content-Type': 'application/json'}),
              )
              ..body = jsonEncode(body);
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 8));
        final text = await response.stream.bytesToString();
        if (response.statusCode != 200) return null;
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
        return null;
      } catch (_) {
        if (attempt + 1 >= attempts) return null;
      } finally {
        client.close();
      }
    }
    return null;
  }

  static Map<String, dynamic> _conclusionRequestBody(
    List<ChatMessage> history,
    String searchBlock,
  ) {
    final messages = history.where((m) => !m.isActivity).map((message) {
      final api = _toApiMessage(message);
      api.remove('event_id');
      api.remove('client_event_id');
      api.remove('generation_id');
      api.remove('epoch_id');
      return api;
    }).toList();
    messages.add({'role': 'user', 'content': searchBlock});
    return {'messages': messages, 'request_kind': 'conclusion'};
  }

  @visibleForTesting
  static Map<String, dynamic> conclusionRequestBodyForTesting(
    List<ChatMessage> history, {
    required String searchBlock,
  }) => _conclusionRequestBody(history, searchBlock);

  /// 发送消息，流式接收回复（走服务器 8816 /chat）。
  /// [history] 为会话历史（含最新一条 user 消息），App 侧已带全部消息，不截断。
  /// [onDelta] 每收到一段增量文本回调一次，[onDone] 结束时回调。
  /// activity 消息（静默活动动态）纯展示，发送前过滤，不注入模型上下文。
  /// 系统提示/记忆/时间注入由 8816 服务端统一拼装，App 只传原始 messages；
  /// 发送的 user 消息与流式回复由 8816 记 raw_events（App 不再 ingest，避免双记）。
  static Future<void> send(
    List<ChatMessage> history, {
    required void Function(String delta) onDelta,

    /// 服务端归一化后的消息部件（parts 序列）：思考/正文/工具/图片统一从这里来。
    /// 收到 part 后，本次请求进入 parts 模式，旧 content/reasoning/image 兼容事件
    /// 只保留给旧服务端，不再重复渲染。
    void Function(ChatMessagePart part)? onPart,

    /// 工具调用前模型已经说出口的中间话术。服务端用独立 SSE 事件推送，
    /// 聊天页落成一条完整 assistant 气泡，不进入最终回复的流式缓冲。
    void Function(String content)? onInterimReply,

    /// 模型主动选择不回复：App 显示低调的 no_response 活动卡片，不落空白气泡。
    void Function(String content)? onNoResponse,

    /// 思考内容增量（reasoning_content）+ 思考轮次 round（v0.2.121：
    /// 8816 推理事件带 round，N 从 1 起，每轮独立思考气泡用；
    /// 缺失按 1 处理），聊天页按轮累积显示用
    void Function(String delta, int round)? onReasoning,

    /// v0.2.118：8816 开始执行 shell 时推 busy 事件（带当前 shell 轮次 round，
    /// 聊天页显示"AI 助手在忙… N"占位，让用户知道模型搞到第几轮了）
    void Function(int round)? onBusy,

    /// v0.2.153：8816 推 termux_pending 事件（模型调 termux 工具要在用户手机上
    /// 执行命令）。回调里 App 本地调 Termux MCP（127.0.0.1:8808）执行并
    /// POST /tool-result 回传；send() 会 await 它完成再继续读流（8816 也在等回传）
    Future<void> Function(int round, List<String> commands, String chatId)?
    onTermuxRequired,

    /// v0.2.153：8816 推 nudge_pending 事件（模型调手机工具要操作用户手机）。
    /// calls: [{"tool": 工具id, "arguments": {...}}]；回调里 App 本地 MethodChannel
    /// "nudge" 调对应工具并 POST /tool-result 回传，send() 等它完成再继续读流
    Future<void> Function(
      int round,
      List<Map<String, dynamic>> calls,
      String chatId,
    )?
    onNudgeRequired,

    /// 8816 gen_image 工具生成完图后推 image 事件（{"url": ...}），
    /// 图直接挂到当前流式回复气泡（不走 /pending，允许主动消息开关关着也显示）
    void Function(String url)? onImage,

    /// 8816 已经开始 SSE 后，上游 reset/timeout 等导致工具链中断。
    /// 不走正常 onDone，不生成 no_response，由页面保留已有过程并标记失败。
    void Function(String code, String message)? onChatError,
    required void Function() onDone,
    required void Function(String error) onError,

    /// 流式末尾 usage 事件回调（token 用量，命中率显示用）
    void Function(MessageUsage usage)? onUsage,

    /// 服务端 raw_events id 回传：用于删除/归档时精确软删服务器记录。
    void Function(int? userRawEventId, int? assistantRawEventId)? onRawEventIds,
  }) async {
    // 图片/文件消息：重新拼接模型侧标注（气泡不显示，模型"看到"图内容）
    final body = await buildChatRequestBody(history);

    // v0.2.114：App 侧兜底剥离 [shell] 标记及命令内容（8816 已先剥一遍，这里防
    // 旧包/边缘残留，用户永远看不到 free -h 这类命令）。标记可能被拆在多个 delta，
    // 状态机跨分片安全；[shell]...[/shell] 与 [shell: 命令] 变体整段剥掉、
    // 只开不闭连同其后内容剥掉（ShellTagStripper 由 sendConclusion 复用，v0.2.115）。
    final shellStripper = ShellTagStripper();

    try {
      final request = http.Request('POST', Uri.parse(chatUrl))
        ..headers.addAll(
          authHeaders({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          }),
        )
        ..body = jsonEncode(body);

      final client = http.Client();
      _activeSendClient = client;
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        onError(
          '服务器返回 ${response.statusCode}: ${body.substring(0, body.length > 200 ? 200 : body.length)}',
        );
        return;
      }

      final stream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      var partsMode = false;
      var sawDone = false;

      // 8816 原样透传 DeepSeek 的 SSE（content/reasoning_content/usage），
      // 流式回复由 8816 落 raw_events，App 不再 ingest。只有明确收到 [DONE]
      // 才算正常结束；socket/代理异常 EOF 不能伪装成 onDone。
      await for (final line in stream) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          sawDone = true;
          break;
        }
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          if (json['type'] == 'part') {
            final rawPart = json['part'];
            if (rawPart is Map) {
              partsMode = true;
              onPart?.call(
                ChatMessagePart.fromJson(
                  rawPart.map((k, v) => MapEntry(k.toString(), v)),
                ),
              );
            }
            continue;
          }
          // v0.2.118：8816 开始执行 shell 时推 busy 事件（只报状态 + 轮次 round，
          // 不含任何命令；round 可能缺失，缺失按 1 处理）
          if (json['type'] == 'busy') {
            final round = json['round'] as int? ?? 1;
            onBusy?.call(round);
            continue;
          }
          if (json['type'] == 'interim_reply') {
            if (partsMode) continue;
            final content = json['content']?.toString() ?? '';
            if (content.isNotEmpty) {
              onInterimReply?.call(content);
            }
            continue;
          }
          if (json['type'] == 'no_response') {
            partsMode = true;
            final content = (json['content']?.toString() ?? '').trim();
            onNoResponse?.call(content.isEmpty ? '无回应' : content);
            continue;
          }
          if (json['type'] == 'metadata') {
            final ids = _rawEventIdsFromMetadata(json);
            onRawEventIds?.call(ids.userRawEventId, ids.assistantRawEventId);
            continue;
          }
          // v0.2.153：Termux 待执行事件 → App 本地执行 + 回传，等待完成再继续读流
          if (json['type'] == 'termux_pending') {
            final chatId = json['chat_id']?.toString() ?? '';
            final round = json['round'] as int? ?? 1;
            final commands = <String>[
              for (final c in (json['commands'] as List<dynamic>? ?? const []))
                c.toString(),
            ];
            if (onTermuxRequired != null && chatId.isNotEmpty) {
              await onTermuxRequired(round, commands, chatId);
            }
            continue;
          }
          // v0.2.153：手机工具待执行事件 → App 本地 MethodChannel 执行 + 回传
          if (json['type'] == 'nudge_pending') {
            final chatId = json['chat_id']?.toString() ?? '';
            final round = json['round'] as int? ?? 1;
            final calls = <Map<String, dynamic>>[
              for (final c in (json['calls'] as List<dynamic>? ?? const []))
                if (c is Map)
                  {
                    'tool': c['tool']?.toString() ?? '',
                    'arguments': c['arguments'] is Map
                        ? Map<String, dynamic>.from(c['arguments'] as Map)
                        : <String, dynamic>{},
                  },
            ];
            if (onNudgeRequired != null && chatId.isNotEmpty) {
              await onNudgeRequired(round, calls, chatId);
            }
            continue;
          }
          // gen_image 工具出图 → 把 URL 挂到当前回复气泡
          if (json['type'] == 'image') {
            if (partsMode) continue;
            final url = json['url']?.toString() ?? '';
            if (url.isNotEmpty) {
              onImage?.call(url);
            }
            continue;
          }
          if (json['type'] == 'chat_error') {
            partsMode = true;
            final code = (json['code']?.toString() ?? 'chat_failed').trim();
            final message = (json['message']?.toString() ?? '').trim();
            if (onChatError != null) {
              onChatError(
                code.isEmpty ? 'chat_failed' : code,
                message.isEmpty ? '回复中断，请稍后重试' : message,
              );
            } else {
              onError(message.isEmpty ? '回复中断，请稍后重试' : message);
            }
            return;
          }
          // DeepSeek 流式末尾：usage 事件（choices 为空数组，带 usage 字段）
          // 8816 已上报命中率，App 只用于气泡显示，不重复上报
          final usageJson = json['usage'] as Map<String, dynamic>?;
          if (usageJson != null && usageJson.isNotEmpty) {
            onUsage?.call(MessageUsage.fromJson(usageJson));
          }
          final choices = json['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final delta =
              (choices.first as Map<String, dynamic>)['delta']
                  as Map<String, dynamic>?;
          final content = delta?['content'] as String?;
          if (!partsMode && content != null && content.isNotEmpty) {
            // v0.2.114：剥离 [shell] 标记后再进正文（8816 已剥，这里兜底）
            final cleaned = shellStripper.process(content);
            if (cleaned.isNotEmpty) {
              onDelta(cleaned);
            }
          }
          // 思考内容（思维链）：单独回调累积，不走正文缓冲。
          // v0.2.121：读 json['round']（8816 推理事件带轮次，缺失按 1）
          final reasoningRaw =
              delta?['reasoning_content'] ?? delta?['reasoning'];
          final reasoning = switch (reasoningRaw) {
            final String s => s,
            final Map m =>
              (m['text'] ?? m['content'] ?? m['summary'] ?? '').toString(),
            final List l =>
              l
                  .map(
                    (e) => e is Map
                        ? (e['text'] ?? e['content'] ?? '').toString()
                        : e.toString(),
                  )
                  .join(),
            _ => null,
          };
          if (!partsMode && reasoning != null && reasoning.isNotEmpty) {
            onReasoning?.call(reasoning, json['round'] as int? ?? 1);
          }
        } catch (_) {
          // 跳过无法解析的行
        }
      }
      if (!sawDone) {
        const code = 'stream_incomplete';
        const message = '回复连接意外中断，后续内容没有完整送达';
        if (onChatError != null) {
          onChatError(code, message);
        } else {
          onError('$message（$code）');
        }
        return;
      }
      onDone();
    } catch (e) {
      onError('连接失败: $e');
    } finally {
      // 正常结束/报错/被 cancel 都释放；cancel 时引用已被拿走并 close，
      // 这里为 null 就不再重复 close。
      final client = _activeSendClient;
      if (client != null) {
        _activeSendClient = null;
        client.close();
      }
    }
  }

  /// 基于搜索结果生成结论（搜索链路第二步）：把 Tavily 结果作为 [searchBlock]
  /// 追加为一条 user 消息（像 OCR 注入那样仅模型可见），模型总结成自然语言结论：
  /// 过滤无关项、结论简洁像人说话、最多附 1 个关键链接、不贴 URL 列表和页面原文。
  /// v0.2.115 起不再直连 DeepSeek：POST 8816 /chat（与主链路同入口，人设/记忆/
  /// 时间注入由服务端统一拼装，body 只带 messages，最后一条是 user），SSE 流式
  /// 解析 choices[0].delta.content 累积成最终正文，60s 超时。
  /// 不 ingest（结论由聊天页并入原回复整体落盘）。activity 消息同 send：发送前
  /// 过滤，不注入模型上下文。
  static Future<void> sendConclusion(
    List<ChatMessage> history, {
    required String searchBlock,
    required void Function(String delta) onDelta,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    final shellStripper = ShellTagStripper();
    try {
      final request = http.Request('POST', Uri.parse(chatUrl))
        ..headers.addAll(
          authHeaders({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          }),
        )
        ..body = jsonEncode(_conclusionRequestBody(history, searchBlock));
      final response = await http.Client()
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        onError(
          '服务器返回 ${response.statusCode}: ${body.substring(0, body.length > 200 ? 200 : body.length)}',
        );
        return;
      }
      final stream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final delta =
              (choices.first as Map<String, dynamic>)['delta']
                  as Map<String, dynamic>?;
          final content = delta?['content'] as String?;
          if (content != null && content.isNotEmpty) {
            // 兜底剥 [shell] 标记（8816 已剥，防边缘残留）
            final cleaned = shellStripper.process(content);
            if (cleaned.isNotEmpty) {
              onDelta(cleaned);
            }
          }
        } catch (_) {
          // 跳过无法解析的行
        }
      }
      onDone();
    } on TimeoutException {
      onError('请求超时');
    } catch (e) {
      onError('连接失败: $e');
    }
  }
}
