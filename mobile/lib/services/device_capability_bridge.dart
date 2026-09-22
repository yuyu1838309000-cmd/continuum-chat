import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_snapshot_api.dart';
import 'device_execution_api.dart';
import 'nudge_api.dart';
import 'termux_api.dart';

class DeviceToolOutcome {
  const DeviceToolOutcome({required this.reported, required this.labels});

  final bool reported;
  final List<String> labels;
}

class DeviceCapabilityBridge {
  DeviceCapabilityBridge._();

  static final DeviceCapabilityBridge instance = DeviceCapabilityBridge._();

  static const String _canonicalJournalPrefsKey =
      'device_bridge_canonical_journal_v1';
  static const String _legacyJournalPrefsKey =
      'device_bridge_legacy_journal_v1';

  final Set<String> _inFlightCanonicalIds = <String>{};
  final Set<String> _completedCanonicalIds = <String>{};
  final Map<String, Map<String, dynamic>> _canonicalResults = {};
  final Map<String, String> _canonicalLabels = {};
  final Map<String, Map<String, dynamic>> _canonicalJournal =
      <String, Map<String, dynamic>>{};
  Future<void>? _canonicalJournalLoadFuture;
  Future<void> _canonicalJournalWriteTail = Future<void>.value();
  bool _canonicalJournalCorrupt = false;

  final Map<String, Map<String, dynamic>> _legacyJournal =
      <String, Map<String, dynamic>>{};
  Future<void>? _legacyJournalLoadFuture;
  Future<void> _legacyJournalWriteTail = Future<void>.value();
  bool _legacyJournalCorrupt = false;

  // Old App/server compatibility only. New Runtime deliveries never use
  // msg_id/chat_id as their execution identity.
  final Set<String> _inFlightPendingMsgIds = <String>{};
  final Set<String> _completedPendingMsgIds = <String>{};

  bool hasCompletedPendingMsgId(String msgId) =>
      _completedPendingMsgIds.contains(msgId);

  @visibleForTesting
  void resetForTesting() {
    _inFlightCanonicalIds.clear();
    _completedCanonicalIds.clear();
    _canonicalResults.clear();
    _canonicalLabels.clear();
    _canonicalJournal.clear();
    _canonicalJournalLoadFuture = null;
    _canonicalJournalWriteTail = Future<void>.value();
    _canonicalJournalCorrupt = false;
    _legacyJournal.clear();
    _legacyJournalLoadFuture = null;
    _legacyJournalWriteTail = Future<void>.value();
    _legacyJournalCorrupt = false;
    _inFlightPendingMsgIds.clear();
    _completedPendingMsgIds.clear();
  }

  String _canonicalKey(String generationId, String toolCallId) =>
      '${generationId.length}:$generationId$toolCallId';

  @visibleForTesting
  static String get canonicalJournalPrefsKeyForTesting =>
      _canonicalJournalPrefsKey;

  @visibleForTesting
  static String get legacyJournalPrefsKeyForTesting => _legacyJournalPrefsKey;

  @visibleForTesting
  static String actionFingerprintForTesting(Map<String, dynamic> tool) =>
      _actionFingerprint(tool);

  Future<void> _ensureCanonicalJournalLoaded() {
    return _canonicalJournalLoadFuture ??= _loadCanonicalJournal();
  }

  Future<void> _loadCanonicalJournal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_canonicalJournalPrefsKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('journal must be a map');
      final journal = <String, Map<String, dynamic>>{};
      final settled = <String>{};
      final results = <String, Map<String, dynamic>>{};
      final labels = <String, String>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map) {
          throw const FormatException('journal record must be a map');
        }
        final record = Map<String, dynamic>.from(entry.value as Map);
        final state = record['state']?.toString() ?? '';
        if (state != 'claimed' &&
            state != 'executed' &&
            state != 'completed' &&
            state != 'closed') {
          throw const FormatException('invalid journal state');
        }
        final key = entry.key.toString();
        final generationId = record['generation_id']?.toString() ?? '';
        final toolCallId = record['tool_call_id']?.toString() ?? '';
        final fingerprint = record['fingerprint']?.toString() ?? '';
        final legacyPreFingerprint = fingerprint.isEmpty && state != 'closed';
        if (generationId.isEmpty ||
            toolCallId.isEmpty ||
            key != _canonicalKey(generationId, toolCallId) ||
            (!legacyPreFingerprint && !_isSha256(fingerprint))) {
          throw const FormatException('invalid journal identity');
        }
        journal[key] = record;
        if (state == 'completed' || state == 'closed') {
          settled.add(key);
          continue;
        }
        if (state == 'executed') {
          final rawResult = record['result'];
          final label = record['label']?.toString();
          if (rawResult is! Map || label == null) {
            throw const FormatException('invalid executed journal record');
          }
          results[key] = Map<String, dynamic>.from(rawResult);
          labels[key] = label;
        }
      }
      _canonicalJournal.addAll(journal);
      _completedCanonicalIds.addAll(settled);
      _canonicalResults.addAll(results);
      _canonicalLabels.addAll(labels);
    } catch (error) {
      _canonicalJournalCorrupt = true;
      _canonicalJournal.clear();
      _completedCanonicalIds.clear();
      _canonicalResults.clear();
      _canonicalLabels.clear();
      debugPrint('[device-bridge] canonical journal invalid: $error');
    }
  }

  Future<void> _persistCanonicalJournal() async {
    final previous = _canonicalJournalWriteTail;
    final gate = Completer<void>();
    _canonicalJournalWriteTail = gate.future;
    await previous;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString(
        _canonicalJournalPrefsKey,
        jsonEncode(_canonicalJournal),
      );
      if (!ok) {
        throw StateError('failed to persist canonical device journal');
      }
    } finally {
      gate.complete();
    }
  }

  String _legacyKey(String msgId, int index) => '${msgId.length}:$msgId:$index';

  Future<void> _ensureLegacyJournalLoaded() {
    return _legacyJournalLoadFuture ??= _loadLegacyJournal();
  }

  Future<void> _loadLegacyJournal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyJournalPrefsKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('journal must be a map');
      final journal = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map) {
          throw const FormatException('journal record must be a map');
        }
        final record = Map<String, dynamic>.from(entry.value as Map);
        final state = record['state']?.toString() ?? '';
        final msgId = record['msg_id']?.toString() ?? '';
        final index = (record['index'] as num?)?.toInt();
        final fingerprint = record['fingerprint']?.toString() ?? '';
        if ((state != 'claimed' &&
                state != 'executed' &&
                state != 'completed') ||
            msgId.isEmpty ||
            index == null ||
            index < 0 ||
            entry.key.toString() != _legacyKey(msgId, index) ||
            !_isSha256(fingerprint)) {
          throw const FormatException('invalid legacy journal record');
        }
        if (state == 'executed' &&
            (record['result'] is! Map || record['label'] is! String)) {
          throw const FormatException('invalid legacy executed record');
        }
        journal[entry.key.toString()] = record;
      }
      _legacyJournal.addAll(journal);
    } catch (error) {
      _legacyJournalCorrupt = true;
      _legacyJournal.clear();
      debugPrint('[device-bridge] legacy journal invalid: $error');
    }
  }

  Future<void> _persistLegacyJournal() async {
    final previous = _legacyJournalWriteTail;
    final gate = Completer<void>();
    _legacyJournalWriteTail = gate.future;
    await previous;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString(
        _legacyJournalPrefsKey,
        jsonEncode(_legacyJournal),
      );
      if (!ok) throw StateError('failed to persist legacy device journal');
    } finally {
      gate.complete();
    }
  }

  Future<void> _writeLegacyRecord({
    required String key,
    required String msgId,
    required int index,
    required String fingerprint,
    required String state,
    Map<String, dynamic>? result,
    String? label,
  }) async {
    _legacyJournal[key] = <String, dynamic>{
      'state': state,
      'msg_id': msgId,
      'index': index,
      'fingerprint': fingerprint,
      'result': ?result,
      'label': ?label,
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
    await _persistLegacyJournal();
  }

  Future<void> _markCanonicalClaimed(
    String key,
    String generationId,
    String toolCallId,
    String fingerprint,
  ) async {
    _canonicalJournal[key] = <String, dynamic>{
      'state': 'claimed',
      'generation_id': generationId,
      'tool_call_id': toolCallId,
      'fingerprint': fingerprint,
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
    await _persistCanonicalJournal();
  }

  Future<void> _markCanonicalExecuted(
    String key,
    String generationId,
    String toolCallId,
    String fingerprint,
    Map<String, dynamic> result,
    String label,
  ) async {
    _canonicalJournal[key] = <String, dynamic>{
      'state': 'executed',
      'generation_id': generationId,
      'tool_call_id': toolCallId,
      'fingerprint': fingerprint,
      'result': result,
      'label': label,
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
    await _persistCanonicalJournal();
  }

  Future<void> _markCanonicalCompleted(
    String key,
    String generationId,
    String toolCallId,
    String fingerprint, {
    bool closed = false,
  }) async {
    _canonicalJournal[key] = <String, dynamic>{
      'state': closed ? 'closed' : 'completed',
      'generation_id': generationId,
      'tool_call_id': toolCallId,
      'fingerprint': fingerprint,
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
    await _persistCanonicalJournal();
  }

  Future<({Map<String, dynamic> result, String label})?>
  _recoverClaimedCanonicalResult(String key) async {
    final record = _canonicalJournal[key];
    if (record == null || record['state'] != 'claimed') return null;
    final result = <String, dynamic>{
      'ok': false,
      'error': 'device_execution_uncertain',
      'message': 'device action outcome unknown after app restart',
    };
    const label = '设备操作状态不确定';
    final generationId = record['generation_id']?.toString() ?? '';
    final toolCallId = record['tool_call_id']?.toString() ?? '';
    final fingerprint = record['fingerprint']?.toString() ?? '';
    await _markCanonicalExecuted(
      key,
      generationId,
      toolCallId,
      fingerprint,
      result,
      label,
    );
    _canonicalResults[key] = result;
    _canonicalLabels[key] = label;
    return (result: result, label: label);
  }

  bool _hasCanonicalIdentity(Map<String, dynamic> call, String generationId) {
    final expectedGenerationId = generationId.trim();
    final callGenerationId = call['generation_id']?.toString().trim() ?? '';
    return expectedGenerationId.isNotEmpty &&
        (call['tool_call_id']?.toString() ?? '').trim().isNotEmpty &&
        (callGenerationId.isEmpty || callGenerationId == expectedGenerationId);
  }

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static dynamic _stableJsonValue(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return <String, dynamic>{
        for (final entry in entries)
          entry.key.toString(): _stableJsonValue(entry.value),
      };
    }
    if (value is Iterable) {
      return [for (final item in value) _stableJsonValue(item)];
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    return value.toString();
  }

  static String _actionFingerprint(Map<String, dynamic> tool) {
    final payload = <String, dynamic>{
      'kind': tool['kind']?.toString() ?? '',
      'tool': tool['tool']?.toString() ?? '',
      'command': tool['command']?.toString() ?? '',
      'arguments': _stableJsonValue(tool['arguments'] ?? const {}),
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  Future<DeviceToolOutcome> executeCanonicalTools({
    required String generationId,
    required List<Map<String, dynamic>> tools,
  }) async {
    await _ensureCanonicalJournalLoaded();
    if (_canonicalJournalCorrupt) {
      return const DeviceToolOutcome(reported: false, labels: []);
    }
    final cleanGenerationId = generationId.trim();
    final canonicalTools = [
      for (final tool in tools)
        if (_hasCanonicalIdentity(tool, cleanGenerationId)) tool,
    ];
    if (canonicalTools.isEmpty || canonicalTools.length != tools.length) {
      return const DeviceToolOutcome(reported: false, labels: []);
    }

    final keys = [
      for (final tool in canonicalTools)
        _canonicalKey(
          cleanGenerationId,
          tool['tool_call_id'].toString().trim(),
        ),
    ];
    if (keys.toSet().length != keys.length) {
      return const DeviceToolOutcome(reported: false, labels: []);
    }
    final fingerprints = [
      for (final tool in canonicalTools) _actionFingerprint(tool),
    ];
    final legacyFingerprintBindings = <int>[];
    for (var index = 0; index < keys.length; index += 1) {
      final record = _canonicalJournal[keys[index]];
      if (record == null) continue;
      final storedFingerprint = record['fingerprint']?.toString() ?? '';
      if (record['generation_id'] != cleanGenerationId ||
          record['tool_call_id'] !=
              canonicalTools[index]['tool_call_id'].toString().trim() ||
          (storedFingerprint.isNotEmpty &&
              storedFingerprint != fingerprints[index])) {
        debugPrint('[device-bridge] canonical identity/payload conflict');
        return const DeviceToolOutcome(reported: false, labels: []);
      }
      if (storedFingerprint.isEmpty) legacyFingerprintBindings.add(index);
    }
    if (legacyFingerprintBindings.isNotEmpty) {
      for (final index in legacyFingerprintBindings) {
        _canonicalJournal[keys[index]]!['fingerprint'] = fingerprints[index];
      }
      try {
        await _persistCanonicalJournal();
      } catch (error) {
        debugPrint(
          '[device-bridge] canonical journal migration failed: $error',
        );
        return const DeviceToolOutcome(reported: false, labels: []);
      }
    }
    if (keys.every(_completedCanonicalIds.contains)) {
      return const DeviceToolOutcome(reported: true, labels: []);
    }
    if (keys.any(_inFlightCanonicalIds.contains)) {
      debugPrint('[device-bridge] canonical tool already in flight');
      return const DeviceToolOutcome(reported: false, labels: []);
    }

    final active = <String>[];
    for (var index = 0; index < canonicalTools.length; index += 1) {
      if (!_completedCanonicalIds.contains(keys[index])) {
        active.add(keys[index]);
      }
    }
    _inFlightCanonicalIds.addAll(active);
    try {
      final reportItems = <Map<String, dynamic>>[];
      final labels = <String>[];
      for (var index = 0; index < canonicalTools.length; index += 1) {
        final toolCall = canonicalTools[index];
        final key = keys[index];
        if (_completedCanonicalIds.contains(key)) continue;
        var result = _canonicalResults[key];
        var label = _canonicalLabels[key];
        if (result == null || label == null) {
          final toolCallId = toolCall['tool_call_id'].toString().trim();
          if (Platform.isAndroid) {
            // The Dart journal is an audit/recovery layer, not a cross-isolate
            // mutex. Persist it first, then let the Android process-wide
            // authority decide whether this engine may touch the phone.
            if (_canonicalJournal[key]?['state'] != 'claimed') {
              await _markCanonicalClaimed(
                key,
                cleanGenerationId,
                toolCallId,
                fingerprints[index],
              );
            }
            final native = await _claimOrExecuteAndroid(
              generationId: cleanGenerationId,
              toolCallId: toolCallId,
              fingerprint: fingerprints[index],
              toolCall: toolCall,
            );
            if (native == null) {
              return const DeviceToolOutcome(reported: false, labels: []);
            }
            if (native.completed) {
              _completedCanonicalIds.add(key);
              try {
                await _markCanonicalCompleted(
                  key,
                  cleanGenerationId,
                  toolCallId,
                  fingerprints[index],
                );
              } catch (error) {
                debugPrint(
                  '[device-bridge] native tombstone mirror failed: $error',
                );
              }
              continue;
            }
            result = native.result;
            label = native.label;
          } else {
            final recovered = await _recoverClaimedCanonicalResult(key);
            if (recovered != null) {
              result = recovered.result;
              label = recovered.label;
            } else {
              await _markCanonicalClaimed(
                key,
                cleanGenerationId,
                toolCallId,
                fingerprints[index],
              );
              final execution = await _executeTool(toolCall);
              result = execution.result;
              label = execution.label;
            }
          }
          _canonicalResults[key] = result;
          _canonicalLabels[key] = label;
          try {
            await _markCanonicalExecuted(
              key,
              cleanGenerationId,
              toolCallId,
              fingerprints[index],
              result,
              label,
            );
          } catch (error) {
            // The durable claim was written before the physical action. If
            // persisting the result fails, a later process must fail closed.
            debugPrint(
              '[device-bridge] canonical result journal failed: $error',
            );
          }
        }
        reportItems.add({
          'tool_call_id': toolCall['tool_call_id'].toString().trim(),
          'result': result,
        });
        labels.add(label);
      }

      if (reportItems.isEmpty && keys.every(_completedCanonicalIds.contains)) {
        return const DeviceToolOutcome(reported: true, labels: []);
      }

      final report = await TermuxApi.reportCanonicalResults(
        cleanGenerationId,
        reportItems,
      );
      if (report.status == CanonicalReportStatus.retryable ||
          report.status == CanonicalReportStatus.rejected) {
        return const DeviceToolOutcome(reported: false, labels: []);
      }
      for (final identity in report.identities) {
        final index = canonicalTools.indexWhere(
          (tool) =>
              tool['tool_call_id'].toString().trim() == identity.toolCallId,
        );
        if (index < 0) continue;
        final key = keys[index];
        _completedCanonicalIds.add(key);
        _canonicalResults.remove(key);
        _canonicalLabels.remove(key);
        if (Platform.isAndroid) {
          final completed = await DeviceExecutionApi.complete(
            generationId: cleanGenerationId,
            toolCallId: canonicalTools[index]['tool_call_id'].toString().trim(),
            fingerprint: fingerprints[index],
          );
          if (!completed) {
            // The native EXECUTED result remains durable and replay-safe.
            debugPrint('[device-bridge] native completion mirror failed');
          }
        }
        try {
          await _markCanonicalCompleted(
            key,
            cleanGenerationId,
            canonicalTools[index]['tool_call_id'].toString().trim(),
            fingerprints[index],
            closed: report.status == CanonicalReportStatus.closed,
          );
        } catch (error) {
          // Keep the executed journal entry when completion persistence fails.
          // A restart may re-report the same result, but must never re-execute.
          debugPrint(
            '[device-bridge] canonical completion journal failed: $error',
          );
        }
      }
      if (report.status == CanonicalReportStatus.closed &&
          !keys.every(_completedCanonicalIds.contains)) {
        return const DeviceToolOutcome(reported: false, labels: []);
      }
      return DeviceToolOutcome(reported: true, labels: labels);
    } catch (error, stackTrace) {
      debugPrint('[device-bridge] canonical tool failed: $error\n$stackTrace');
      return const DeviceToolOutcome(reported: false, labels: []);
    } finally {
      _inFlightCanonicalIds.removeAll(active);
    }
  }

  Future<({Map<String, dynamic> result, String label, bool completed})?>
  _claimOrExecuteAndroid({
    required String generationId,
    required String toolCallId,
    required String fingerprint,
    required Map<String, dynamic> toolCall,
  }) async {
    final claim = await DeviceExecutionApi.claim(
      generationId: generationId,
      toolCallId: toolCallId,
      fingerprint: fingerprint,
    );
    switch (claim.status) {
      case DeviceExecutionClaimStatus.completed:
        return (result: const <String, dynamic>{}, label: '', completed: true);
      case DeviceExecutionClaimStatus.executed:
        final result = claim.result;
        if (result == null) return null;
        return (
          result: result,
          label: _labelForRecoveredResult(toolCall, result),
          completed: false,
        );
      case DeviceExecutionClaimStatus.acquired:
        final execution = await _executeTool(toolCall);
        final stored = await DeviceExecutionApi.storeResult(
          generationId: generationId,
          toolCallId: toolCallId,
          fingerprint: fingerprint,
          result: execution.result,
        );
        if (!stored) return null;
        return (
          result: execution.result,
          label: execution.label,
          completed: false,
        );
      case DeviceExecutionClaimStatus.inFlight:
      case DeviceExecutionClaimStatus.conflict:
      case DeviceExecutionClaimStatus.storageError:
      case DeviceExecutionClaimStatus.unavailable:
        return null;
    }
  }

  String _labelForRecoveredResult(
    Map<String, dynamic> toolCall,
    Map<String, dynamic> result,
  ) {
    if (result['error'] == 'device_execution_uncertain') {
      return '设备操作状态不确定';
    }
    final kind = toolCall['kind']?.toString() ?? '';
    final tool = toolCall['tool']?.toString() ?? '';
    return kind == 'termux' || tool == 'termux'
        ? '✓ 搞定了！'
        : nudgeActionText(tool);
  }

  Future<({Map<String, dynamic> result, String label})> _executeTool(
    Map<String, dynamic> toolCall,
  ) async {
    final kind = toolCall['kind']?.toString() ?? '';
    final tool = toolCall['tool']?.toString() ?? '';
    final rawArgs = toolCall['arguments'];
    final arguments = rawArgs is Map<String, dynamic>
        ? rawArgs
        : rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : <String, dynamic>{};
    if (kind == 'termux' || tool == 'termux') {
      final command = (toolCall['command'] ?? arguments['command'])
          ?.toString()
          .trim();
      final result = await TermuxApi.runCommand(command ?? '');
      return (result: result.toJson(), label: '✓ 搞定了！');
    }
    final result = await executeNudge(tool, arguments);
    return (result: result, label: nudgeActionText(tool));
  }

  Future<bool> executeStreamTermux({
    required String generationId,
    required List<Map<String, dynamic>> calls,
  }) async {
    final outcome = await executeCanonicalTools(
      generationId: generationId,
      tools: [
        for (final call in calls) {...call, 'kind': 'termux'},
      ],
    );
    return outcome.reported;
  }

  Future<bool> executeLegacyStreamTermux({
    required String chatId,
    required int round,
    required List<String> commands,
  }) async {
    final results = <TermuxCommandResult>[];
    for (final command in commands) {
      if (command.trim().isEmpty) continue;
      results.add(await TermuxApi.runCommand(command));
    }
    return TermuxApi.reportResult(chatId, round, results);
  }

  Future<bool> executeStreamNudge({
    required String generationId,
    required List<Map<String, dynamic>> calls,
  }) async {
    final outcome = await executeCanonicalTools(
      generationId: generationId,
      tools: [
        for (final call in calls) {...call, 'kind': 'nudge'},
      ],
    );
    return outcome.reported;
  }

  Future<bool> executeLegacyStreamNudge({
    required String chatId,
    required int round,
    required List<Map<String, dynamic>> calls,
  }) async {
    final results = <Map<String, dynamic>>[];
    for (final call in calls) {
      final execution = await _executeTool({...call, 'kind': 'nudge'});
      results.add(execution.result);
    }
    return TermuxApi.reportResults(chatId, round, results);
  }

  Future<DeviceToolOutcome> executePendingTools({
    required String msgId,
    required List<Map<String, dynamic>> tools,
    String generationId = '',
  }) async {
    final canonicalGenerationId = generationId.trim().isNotEmpty
        ? generationId.trim()
        : tools
              .map((tool) => tool['generation_id']?.toString().trim() ?? '')
              .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final hasCanonicalSignal =
        canonicalGenerationId.isNotEmpty ||
        tools.any(
          (tool) =>
              (tool['generation_id']?.toString() ?? '').trim().isNotEmpty ||
              (tool['tool_call_id']?.toString() ?? '').trim().isNotEmpty,
        );
    if (hasCanonicalSignal) {
      if (canonicalGenerationId.isEmpty ||
          tools.isEmpty ||
          !tools.every(
            (tool) => _hasCanonicalIdentity(tool, canonicalGenerationId),
          )) {
        debugPrint('[device-bridge] invalid canonical pending identity');
        return const DeviceToolOutcome(reported: false, labels: []);
      }
      return executeCanonicalTools(
        generationId: canonicalGenerationId,
        tools: tools,
      );
    }
    if (msgId.trim().isEmpty || tools.isEmpty) {
      return const DeviceToolOutcome(reported: false, labels: []);
    }
    await _ensureLegacyJournalLoaded();
    if (_legacyJournalCorrupt) {
      return const DeviceToolOutcome(reported: false, labels: []);
    }
    final cleanMsgId = msgId.trim();
    final keys = [
      for (var index = 0; index < tools.length; index += 1)
        _legacyKey(cleanMsgId, index),
    ];
    final fingerprints = [for (final tool in tools) _actionFingerprint(tool)];
    for (var index = 0; index < tools.length; index += 1) {
      final kind = tools[index]['kind']?.toString() ?? '';
      final valid = switch (kind) {
        'termux' =>
          (tools[index]['command']?.toString() ?? '').trim().isNotEmpty,
        'nudge' => (tools[index]['tool']?.toString() ?? '').trim().isNotEmpty,
        _ => false,
      };
      final record = _legacyJournal[keys[index]];
      if (!valid ||
          (record != null &&
              (record['msg_id'] != cleanMsgId ||
                  record['index'] != index ||
                  record['fingerprint'] != fingerprints[index]))) {
        debugPrint('[device-bridge] invalid/conflicting legacy tool batch');
        return const DeviceToolOutcome(reported: false, labels: []);
      }
    }
    final records = [for (final key in keys) _legacyJournal[key]];
    if (records.any((record) => record?['state'] == 'completed')) {
      if (!records.every((record) => record?['state'] == 'completed')) {
        return const DeviceToolOutcome(reported: false, labels: []);
      }
      _completedPendingMsgIds.add(cleanMsgId);
      return const DeviceToolOutcome(reported: true, labels: []);
    }
    if (_inFlightPendingMsgIds.contains(cleanMsgId)) {
      debugPrint(
        '[device-bridge] in-flight pending tool skipped msg_id=$cleanMsgId',
      );
      return const DeviceToolOutcome(reported: false, labels: []);
    }

    _inFlightPendingMsgIds.add(cleanMsgId);
    try {
      final results = <Map<String, dynamic>>[];
      final labels = <String>[];
      for (var index = 0; index < tools.length; index += 1) {
        final key = keys[index];
        final record = _legacyJournal[key];
        Map<String, dynamic> result;
        String label;
        if (record?['state'] == 'executed') {
          result = Map<String, dynamic>.from(record!['result'] as Map);
          label = record['label'].toString();
        } else if (record?['state'] == 'claimed') {
          result = <String, dynamic>{
            'ok': false,
            'error': 'device_execution_uncertain',
            'message': 'device action outcome unknown after app restart',
          };
          label = '设备操作状态不确定';
          await _writeLegacyRecord(
            key: key,
            msgId: cleanMsgId,
            index: index,
            fingerprint: fingerprints[index],
            state: 'executed',
            result: result,
            label: label,
          );
        } else {
          await _writeLegacyRecord(
            key: key,
            msgId: cleanMsgId,
            index: index,
            fingerprint: fingerprints[index],
            state: 'claimed',
          );
          final execution = await _executeTool(tools[index]);
          result = execution.result;
          label = execution.label;
          await _writeLegacyRecord(
            key: key,
            msgId: cleanMsgId,
            index: index,
            fingerprint: fingerprints[index],
            state: 'executed',
            result: result,
            label: label,
          );
        }
        results.add(result);
        labels.add(label);
      }

      final reported = await TermuxApi.reportResultsByMsgId(
        cleanMsgId,
        results,
      );
      if (reported) {
        for (var index = 0; index < tools.length; index += 1) {
          await _writeLegacyRecord(
            key: keys[index],
            msgId: cleanMsgId,
            index: index,
            fingerprint: fingerprints[index],
            state: 'completed',
          );
        }
        _completedPendingMsgIds.add(cleanMsgId);
        return DeviceToolOutcome(reported: true, labels: labels);
      }
    } catch (e) {
      debugPrint('[device-bridge] pending tool failed msg_id=$cleanMsgId: $e');
    } finally {
      _inFlightPendingMsgIds.remove(cleanMsgId);
    }
    return const DeviceToolOutcome(reported: false, labels: []);
  }

  Future<Map<String, dynamic>> executeNudge(
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final raw = tool == NudgeApi.cameraSnapshot
        ? await CameraSnapshotApi.run()
        : await NudgeApi.call(tool, arguments: arguments);
    var ok = true;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map && parsed['error'] != null) ok = false;
    } catch (_) {
      ok = false;
    }
    return {'command': tool, 'ok': ok, 'output': raw};
  }

  String nudgeActionText(String toolId) {
    return switch (toolId) {
      'get_foreground_app' => 'AI 助手看了你的前台应用',
      'device_status' => 'AI 助手查了你的设备状态',
      'screenshot_analyze' => 'AI 助手截了屏看你在干嘛',
      'camera_snapshot' => 'AI 助手用后置摄像头拍了照',
      'get_steps' => 'AI 助手查了你的今日步数',
      'get_location' => 'AI 助手看了你的位置',
      'get_notifications' => 'AI 助手看了你的通知',
      'calendar_query' => 'AI 助手查了你的日程',
      'calendar_create' => 'AI 助手给你日程加了安排',
      'sensor_data' => 'AI 助手读了你手机的传感器',
      'read_screen' => 'AI 助手读了你屏幕上的内容',
      'media_play_pause' => 'AI 助手控制了你的播放',
      'media_next' => 'AI 助手切了歌',
      'media_previous' => 'AI 助手切回了上一首',
      'set_alarm' => 'AI 助手给你设了闹钟',
      'lock_screen' => 'AI 助手锁了你的屏幕',
      'wake_up' => 'AI 助手唤醒了你的手机',
      'press_back' => 'AI 助手按了返回键',
      'press_home' => 'AI 助手按了主页键',
      'open_app' => 'AI 助手打开了应用',
      'switch_to_continuum' => 'AI 助手把你拉回了Continuum Chat',
      'ping' => 'AI 助手测了你手机的连通性',
      _ => 'AI 助手用了「$toolId」工具',
    };
  }
}
