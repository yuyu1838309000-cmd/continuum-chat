import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'chat_runtime_controller.dart';
import 'device_capability_bridge.dart';
import 'music_player.dart';
import 'server_config.dart';

class AppEventClient {
  AppEventClient._();

  static final AppEventClient instance = AppEventClient._();
  static const Duration _pollInterval = Duration(seconds: 8);
  static const String _allowProactiveKey = 'allow_proactive';
  static const String _handledPendingKey = 'app_event_handled_pending_ids_v1';
  static const int _handledPendingMax = 256;

  Timer? _timer;
  bool _polling = false;

  void start() {
    _timer ??= Timer.periodic(_pollInterval, (_) => unawaited(pollOnce()));
    unawaited(pollOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  Future<void> pollOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      final response = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/pending')),
            headers: ChatApi.authHeaders({'X-Continuum-Ack': '1'}),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return;
      await dispatchPending([
        for (final item in decoded)
          if (item is Map)
            item.map((key, value) => MapEntry(key.toString(), value)),
      ]);
    } catch (e) {
      debugPrint('[app-event] pending poll error: $e');
    } finally {
      _polling = false;
    }
  }

  @visibleForTesting
  Future<void> dispatchPending(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    final allow = prefs.getBool(_allowProactiveKey) ?? true;
    final handled = <String>{
      ...prefs.getStringList(_handledPendingKey) ?? const [],
    };
    final ackIds = <String>{};
    var handledChanged = false;

    for (final item in items) {
      final id = (item['id'] as String? ?? '').trim();
      if (id.isNotEmpty && handled.contains(id)) {
        ackIds.add(id);
        continue;
      }

      final type = item['type']?.toString() ?? '';
      if (type == 'music') {
        await MusicPlayer.instance.handlePendingMessage(item);
        if (id.isNotEmpty) {
          handled.add(id);
          handledChanged = true;
          ackIds.add(id);
        }
        continue;
      }

      final isActivity = type == 'activity' || type == 'no_response';
      if (!allow && !isActivity) {
        if (id.isNotEmpty) {
          handled.add(id);
          handledChanged = true;
          ackIds.add(id);
        }
        continue;
      }

      if (_hasVisibleContent(item)) {
        await ChatRuntimeController.instance.handlePendingItems([item]);
      }

      final tools = _toolsFromItem(item);
      if (tools.isEmpty) {
        if (id.isNotEmpty) {
          handled.add(id);
          handledChanged = true;
          ackIds.add(id);
        }
        continue;
      }
      if (id.isEmpty) {
        debugPrint('[app-event] pending tools missing msg_id');
        continue;
      }

      final outcome = await DeviceCapabilityBridge.instance.executePendingTools(
        msgId: id,
        tools: tools,
        generationId: _generationIdFromItem(item),
      );
      if (outcome.labels.isNotEmpty) {
        await ChatRuntimeController.instance.appendToolDoneLabels(
          outcome.labels,
        );
      }
      if (outcome.reported) {
        handled.add(id);
        handledChanged = true;
        ackIds.add(id);
      }
    }

    if (handledChanged) {
      final ids = handled.toList();
      final keep = ids.length <= _handledPendingMax
          ? ids
          : ids.sublist(ids.length - _handledPendingMax);
      await prefs.setStringList(_handledPendingKey, keep);
    }
    if (ackIds.isNotEmpty) {
      unawaited(ChatApi.ackPending(ackIds.toList()));
    }
  }

  List<Map<String, dynamic>> _toolsFromItem(Map<String, dynamic> item) {
    return <Map<String, dynamic>>[
      for (final tool in (item['tools'] as List<dynamic>? ?? const []))
        if (tool is Map)
          tool.map((key, value) => MapEntry(key.toString(), value)),
    ];
  }

  String _generationIdFromItem(Map<String, dynamic> item) {
    final direct = item['generation_id']?.toString().trim() ?? '';
    if (direct.isNotEmpty) return direct;
    final metadata = item['metadata'];
    return metadata is Map
        ? metadata['generation_id']?.toString().trim() ?? ''
        : '';
  }

  bool _hasVisibleContent(Map<String, dynamic> item) {
    final content = (item['content'] as String? ?? '').trim();
    final imageUrl = (item['imageUrl'] as String? ?? '').trim();
    final imageUrls = item['imageUrls'];
    return content.isNotEmpty ||
        imageUrl.isNotEmpty ||
        (imageUrls is List &&
            imageUrls.any((url) => url is String && url.trim().isNotEmpty));
  }
}
