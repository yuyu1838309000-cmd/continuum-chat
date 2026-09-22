import 'dart:convert';

import 'package:flutter/services.dart';

enum DeviceExecutionClaimStatus {
  acquired,
  inFlight,
  executed,
  completed,
  conflict,
  storageError,
  unavailable,
}

class DeviceExecutionClaim {
  const DeviceExecutionClaim({required this.status, this.result});

  final DeviceExecutionClaimStatus status;
  final Map<String, dynamic>? result;
}

/// Android process-wide authority shared by the UI and foreground-task engines.
class DeviceExecutionApi {
  DeviceExecutionApi._();

  static const MethodChannel _channel = MethodChannel(
    'continuum/device_execution',
  );

  static Future<DeviceExecutionClaim> claim({
    required String generationId,
    required String toolCallId,
    required String fingerprint,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('claim', {
        'generation_id': generationId,
        'tool_call_id': toolCallId,
        'fingerprint': fingerprint,
      });
      final status = switch (raw?['status']?.toString()) {
        'acquired' => DeviceExecutionClaimStatus.acquired,
        'in_flight' => DeviceExecutionClaimStatus.inFlight,
        'executed' => DeviceExecutionClaimStatus.executed,
        'completed' => DeviceExecutionClaimStatus.completed,
        'conflict' => DeviceExecutionClaimStatus.conflict,
        'storage_error' => DeviceExecutionClaimStatus.storageError,
        _ => DeviceExecutionClaimStatus.unavailable,
      };
      final resultJson = raw?['result_json']?.toString();
      Map<String, dynamic>? result;
      if (resultJson != null && resultJson.isNotEmpty) {
        final decoded = jsonDecode(resultJson);
        if (decoded is! Map) {
          return const DeviceExecutionClaim(
            status: DeviceExecutionClaimStatus.storageError,
          );
        }
        result = Map<String, dynamic>.from(decoded);
      }
      if (status == DeviceExecutionClaimStatus.executed && result == null) {
        return const DeviceExecutionClaim(
          status: DeviceExecutionClaimStatus.storageError,
        );
      }
      return DeviceExecutionClaim(status: status, result: result);
    } catch (_) {
      return const DeviceExecutionClaim(
        status: DeviceExecutionClaimStatus.unavailable,
      );
    }
  }

  static Future<bool> storeResult({
    required String generationId,
    required String toolCallId,
    required String fingerprint,
    required Map<String, dynamic> result,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('storeResult', {
            'generation_id': generationId,
            'tool_call_id': toolCallId,
            'fingerprint': fingerprint,
            'result_json': jsonEncode(result),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> complete({
    required String generationId,
    required String toolCallId,
    required String fingerprint,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('complete', {
            'generation_id': generationId,
            'tool_call_id': toolCallId,
            'fingerprint': fingerprint,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
