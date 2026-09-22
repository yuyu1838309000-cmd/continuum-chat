import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'device_capability_bridge.dart';

/// Restricted `/pending` consumer for the foreground-service isolate.
///
/// It never renders messages and never ACKs non-tool or non-canonical items.
/// Result reporting is completed by [DeviceCapabilityBridge] before ACK.
class BackgroundDeviceToolClient {
  bool _polling = false;

  Future<void> pollOnce({
    required String host,
    required int runtimePort,
    required bool allowProactive,
  }) async {
    if (_polling) return;
    _polling = true;
    try {
      final response = await http
          .get(
            Uri(
              scheme: 'http',
              host: host,
              port: runtimePort,
              path: '/pending',
            ),
            headers: ChatApi.authHeaders({'X-Continuum-Ack': '1'}),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return;

      final ackIds = <String>{};
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final item = raw.map((key, value) => MapEntry(key.toString(), value));
        final type = item['type']?.toString() ?? '';
        final isActivity = type == 'activity' || type == 'no_response';
        if (!allowProactive && !isActivity) continue;

        final id = (item['id']?.toString() ?? '').trim();
        final generationId = generationIdFromPendingItem(item);
        final tools = canonicalDeviceToolsFromPendingItem(
          item,
          generationId: generationId,
        );
        if (id.isEmpty || generationId.isEmpty || tools == null) continue;

        final outcome = await DeviceCapabilityBridge.instance
            .executePendingTools(
              msgId: id,
              tools: tools,
              generationId: generationId,
            );
        // A background worker must never consume visible chat content. If a
        // mixed content+tool item ever appears, finish the tool work but leave
        // the queue item for the UI to render and ACK later.
        if (outcome.reported && !pendingItemHasVisibleContent(item)) {
          ackIds.add(id);
        }
      }
      if (ackIds.isNotEmpty) {
        // executePendingTools only reports true after a canonical result ACK or
        // terminal close. Pending is never ACKed ahead of that point.
        await ChatApi.ackPending(ackIds.toList());
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[background-device-tools] pending poll failed: $error\n$stackTrace',
      );
    } finally {
      _polling = false;
    }
  }
}

@visibleForTesting
bool pendingItemHasVisibleContent(Map<String, dynamic> item) {
  final content = (item['content']?.toString() ?? '').trim();
  final imageUrl = (item['imageUrl']?.toString() ?? '').trim();
  final imageUrls = item['imageUrls'];
  return content.isNotEmpty ||
      imageUrl.isNotEmpty ||
      (imageUrls is List &&
          imageUrls.any((url) => url is String && url.trim().isNotEmpty));
}

@visibleForTesting
String generationIdFromPendingItem(Map<String, dynamic> item) {
  final direct = item['generation_id']?.toString().trim() ?? '';
  if (direct.isNotEmpty) return direct;
  final metadata = item['metadata'];
  return metadata is Map
      ? metadata['generation_id']?.toString().trim() ?? ''
      : '';
}

/// Returns null unless the entire batch is a canonical nudge/Termux batch.
@visibleForTesting
List<Map<String, dynamic>>? canonicalDeviceToolsFromPendingItem(
  Map<String, dynamic> item, {
  required String generationId,
}) {
  final rawTools = item['tools'];
  if (generationId.isEmpty || rawTools is! List || rawTools.isEmpty) {
    return null;
  }
  final tools = <Map<String, dynamic>>[];
  for (final raw in rawTools) {
    if (raw is! Map) return null;
    final tool = raw.map((key, value) => MapEntry(key.toString(), value));
    final callId = (tool['tool_call_id']?.toString() ?? '').trim();
    final callGeneration = (tool['generation_id']?.toString() ?? '').trim();
    if (callId.isEmpty ||
        (callGeneration.isNotEmpty && callGeneration != generationId)) {
      return null;
    }
    final kind = (tool['kind']?.toString() ?? '').trim();
    final toolId = (tool['tool']?.toString() ?? '').trim();
    final valid = switch (kind) {
      // camera_snapshot uses Flutter's camera plugin and remains foreground-only;
      // do not claim it in the service isolate, otherwise a background camera
      // restriction could turn a retryable pending call into a terminal error.
      'nudge' => toolId.isNotEmpty && toolId != 'camera_snapshot',
      'termux' =>
        (tool['command']?.toString() ?? '').trim().isNotEmpty ||
            (tool['arguments'] is Map &&
                ((tool['arguments'] as Map)['command']?.toString() ?? '')
                    .trim()
                    .isNotEmpty),
      _ => false,
    };
    if (!valid) return null;
    tools.add(tool);
  }
  return tools;
}
