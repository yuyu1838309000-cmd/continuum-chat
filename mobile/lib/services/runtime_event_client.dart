import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'server_config.dart';

enum GenerationTerminalStatus {
  running,
  waitingTool,
  completed,
  failed,
  cancelled,
  replayUnavailable,
}

enum CancelGenerationOutcome {
  cancelled,
  reconciled,
  alreadyTerminal,
  replayUnavailable,
  failed,
}

GenerationTerminalStatus generationStatusFromString(String? raw) {
  return switch ((raw ?? '').trim()) {
    'waiting_tool' => GenerationTerminalStatus.waitingTool,
    'completed' => GenerationTerminalStatus.completed,
    'failed' => GenerationTerminalStatus.failed,
    'cancelled' => GenerationTerminalStatus.cancelled,
    'replay_unavailable' => GenerationTerminalStatus.replayUnavailable,
    _ => GenerationTerminalStatus.running,
  };
}

String generationStatusToString(GenerationTerminalStatus status) {
  return switch (status) {
    GenerationTerminalStatus.running => 'running',
    GenerationTerminalStatus.waitingTool => 'waiting_tool',
    GenerationTerminalStatus.completed => 'completed',
    GenerationTerminalStatus.failed => 'failed',
    GenerationTerminalStatus.cancelled => 'cancelled',
    GenerationTerminalStatus.replayUnavailable => 'replay_unavailable',
  };
}

bool generationStatusIsTerminal(GenerationTerminalStatus status) {
  return switch (status) {
    GenerationTerminalStatus.completed ||
    GenerationTerminalStatus.failed ||
    GenerationTerminalStatus.cancelled ||
    GenerationTerminalStatus.replayUnavailable => true,
    GenerationTerminalStatus.running ||
    GenerationTerminalStatus.waitingTool => false,
  };
}

class GenerationCursor {
  const GenerationCursor({
    required this.threadId,
    required this.generationId,
    required this.lastSeq,
    required this.status,
    this.userClientEventId,
    this.assistantClientEventId,
  });

  final String threadId;
  final String generationId;
  final int lastSeq;
  final GenerationTerminalStatus status;
  final String? userClientEventId;
  final String? assistantClientEventId;

  bool get terminal => generationStatusIsTerminal(status);

  GenerationCursor copyWith({
    String? threadId,
    String? generationId,
    int? lastSeq,
    GenerationTerminalStatus? status,
    String? userClientEventId,
    String? assistantClientEventId,
  }) {
    return GenerationCursor(
      threadId: threadId ?? this.threadId,
      generationId: generationId ?? this.generationId,
      lastSeq: lastSeq ?? this.lastSeq,
      status: status ?? this.status,
      userClientEventId: userClientEventId ?? this.userClientEventId,
      assistantClientEventId:
          assistantClientEventId ?? this.assistantClientEventId,
    );
  }

  Map<String, dynamic> toJson() => {
    'thread': threadId,
    'generation_id': generationId,
    'last_seq': lastSeq,
    'status': generationStatusToString(status),
    if (userClientEventId != null) 'user_client_event_id': userClientEventId,
    if (assistantClientEventId != null)
      'assistant_client_event_id': assistantClientEventId,
  };

  static GenerationCursor? fromJson(Map<String, dynamic> json) {
    final generationId = (json['generation_id'] ?? '').toString().trim();
    if (generationId.isEmpty) return null;
    return GenerationCursor(
      threadId: (json['thread'] ?? 'main').toString().trim().isEmpty
          ? 'main'
          : (json['thread'] ?? 'main').toString().trim(),
      generationId: generationId,
      lastSeq: (json['last_seq'] as num?)?.toInt() ?? 0,
      status: generationStatusFromString(json['status']?.toString()),
      userClientEventId: json['user_client_event_id']?.toString(),
      assistantClientEventId: json['assistant_client_event_id']?.toString(),
    );
  }
}

class PendingRuntimeCommand {
  const PendingRuntimeCommand({
    required this.kind,
    required this.targetEventId,
    required this.payloadFingerprint,
    required this.generationId,
    required this.userClientEventId,
    required this.assistantClientEventId,
    required this.epochId,
    this.localContent,
  });

  final String kind;
  final String targetEventId;
  final String payloadFingerprint;
  final String generationId;
  final String userClientEventId;
  final String assistantClientEventId;
  final String epochId;
  final String? localContent;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'target_event_id': targetEventId,
    'payload_fingerprint': payloadFingerprint,
    'generation_id': generationId,
    'user_client_event_id': userClientEventId,
    'assistant_client_event_id': assistantClientEventId,
    'epoch_id': epochId,
    if (localContent != null) 'local_content': localContent,
  };

  static PendingRuntimeCommand? fromJson(Map<String, dynamic> json) {
    final values = [
      json['kind'],
      json['target_event_id'],
      json['payload_fingerprint'],
      json['generation_id'],
      json['user_client_event_id'],
      json['assistant_client_event_id'],
      json['epoch_id'],
    ].map((value) => (value ?? '').toString().trim()).toList();
    if (values.any((value) => value.isEmpty)) return null;
    return PendingRuntimeCommand(
      kind: values[0],
      targetEventId: values[1],
      payloadFingerprint: values[2],
      generationId: values[3],
      userClientEventId: values[4],
      assistantClientEventId: values[5],
      epochId: values[6],
      localContent: json['local_content']?.toString(),
    );
  }
}

class RuntimeSseEvent {
  const RuntimeSseEvent({required this.seq, required this.payloads});

  final int? seq;

  /// One server replay seq can contain several SSE `data:` frames because the
  /// generation buffer sequences writer writes, not individual SSE frames.
  /// Keep them together so the client advances `last_seq` only after the whole
  /// replay unit has been applied durably.
  final List<String> payloads;

  String get data => payloads.isEmpty ? '' : payloads.first;
  bool get isDonePayload => payloads.length == 1 && data.trim() == '[DONE]';
  bool get hasDonePayload =>
      payloads.any((payload) => payload.trim() == '[DONE]');

  Map<String, dynamic>? get json => jsonForPayload(data);

  Iterable<Map<String, dynamic>> get jsonPayloads sync* {
    for (final payload in payloads) {
      final decoded = jsonForPayload(payload);
      if (decoded != null) yield decoded;
    }
  }

  static Map<String, dynamic>? jsonForPayload(String payload) {
    if (payload.trim() == '[DONE]') return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

class RuntimeSseParser extends StreamTransformerBase<String, RuntimeSseEvent> {
  const RuntimeSseParser();

  @override
  Stream<RuntimeSseEvent> bind(Stream<String> stream) async* {
    int? seq;
    var frame = StringBuffer();
    var payloads = <String>[];

    void finishFrame() {
      if (frame.isEmpty) return;
      payloads.add(frame.toString().trimRight());
      frame = StringBuffer();
    }

    RuntimeSseEvent? finishBatch() {
      finishFrame();
      if (payloads.isEmpty) return null;
      final batch = RuntimeSseEvent(
        seq: seq,
        payloads: List<String>.unmodifiable(payloads),
      );
      payloads = <String>[];
      return batch;
    }

    await for (final line in stream) {
      if (line.startsWith('id:')) {
        final previous = finishBatch();
        if (previous != null) yield previous;
        seq = int.tryParse(line.substring(3).trim());
        continue;
      }
      if (line.isEmpty) {
        finishFrame();
        final terminalFrame = payloads.any((payload) {
          final json = RuntimeSseEvent.jsonForPayload(payload);
          final type = json?['type']?.toString();
          return type == 'generation_terminal' ||
              type == 'generation_cancelled';
        });
        if (terminalFrame) {
          final terminalBatch = finishBatch();
          if (terminalBatch != null) yield terminalBatch;
          seq = null;
        }
        continue;
      }
      if (line.startsWith('data:')) {
        if (frame.isNotEmpty) frame.write('\n');
        frame.write(line.substring(5).trimLeft());
      }
    }
    final finalBatch = finishBatch();
    if (finalBatch != null) yield finalBatch;
  }
}

typedef RuntimeEventApplier =
    FutureOr<void> Function(RuntimeSseEvent event, GenerationCursor cursor);

enum _ReplaySnapshotOutcome {
  terminalApplied,
  acceptedNonTerminal,
  unavailable,
}

class RuntimeEventClient {
  RuntimeEventClient({
    this.responseHeaderTimeout = const Duration(seconds: 20),
    this.bodyIdleTimeout = const Duration(seconds: 20),
    this.initialRetryDelay = const Duration(milliseconds: 250),
    this.maxRetryDelay = const Duration(seconds: 8),
    this.startPostAttempts = 2,
  });

  static final RuntimeEventClient instance = RuntimeEventClient();
  static const String _cursorPrefsKey = 'runtime_active_generation_cursor_v1';
  static const String _pendingCommandPrefsKey =
      'runtime_pending_command_acceptance_v1';
  final Duration responseHeaderTimeout;
  final Duration bodyIdleTimeout;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;
  final int startPostAttempts;

  final RuntimeSseParser _parser = const RuntimeSseParser();
  final Set<int> _appliedSeqs = <int>{};
  final Set<http.Client> _streamClients = <http.Client>{};
  GenerationCursor? _cursor;
  Future<void>? _resumeFuture;
  int _wakeVersion = 0;

  GenerationCursor? get cursor => _cursor;

  /// Interrupts a possibly half-open SSE socket. Its existing owner remains
  /// responsible for reconnecting the same generation from the durable cursor.
  void wakeReconnect() {
    _wakeVersion += 1;
    for (final client in _streamClients.toList(growable: false)) {
      client.close();
    }
  }

  static String newRuntimeId(String prefix) {
    final micros = DateTime.now().microsecondsSinceEpoch;
    final nonce = Random().nextInt(1 << 32).toRadixString(16);
    return '$prefix-$micros-$nonce';
  }

  Future<GenerationCursor?> loadCursor() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cursorPrefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      _cursor = GenerationCursor.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      return _cursor;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCursor({String? generationId}) async {
    final existing = _cursor ?? await loadCursor();
    if (generationId != null &&
        existing != null &&
        existing.generationId != generationId) {
      return;
    }
    _cursor = null;
    _appliedSeqs.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cursorPrefsKey);
  }

  Future<void> _saveCursor(GenerationCursor cursor) async {
    _cursor = cursor;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cursorPrefsKey, jsonEncode(cursor.toJson()));
  }

  Future<void> prepareGeneration({
    required String generationId,
    required String userClientEventId,
    required String assistantClientEventId,
    String threadId = 'main',
  }) async {
    final existing = _cursor ?? await loadCursor();
    if (existing != null &&
        !existing.terminal &&
        existing.generationId != generationId) {
      throw const RuntimeException(
        'generation_already_active',
        '已有一轮生成仍在服务器运行',
      );
    }
    await _saveCursor(
      GenerationCursor(
        threadId: threadId,
        generationId: generationId,
        lastSeq: existing?.generationId == generationId ? existing!.lastSeq : 0,
        status: existing?.generationId == generationId
            ? existing!.status
            : GenerationTerminalStatus.running,
        userClientEventId: userClientEventId,
        assistantClientEventId: assistantClientEventId,
      ),
    );
  }

  Future<PendingRuntimeCommand> prepareMutationCommand({
    required String kind,
    required String targetEventId,
    required String payloadFingerprint,
    required String epochId,
    String? localContent,
    String? userClientEventId,
    String? assistantClientEventId,
  }) async {
    final existing = await loadPendingCommand();
    if (existing != null) {
      if (existing.kind == kind &&
          existing.targetEventId == targetEventId &&
          existing.payloadFingerprint == payloadFingerprint &&
          existing.epochId == epochId) {
        await prepareGeneration(
          generationId: existing.generationId,
          userClientEventId: existing.userClientEventId,
          assistantClientEventId: existing.assistantClientEventId,
        );
        return existing;
      }
      throw const RuntimeException(
        'command_acceptance_uncertain',
        '上一条命令是否已被服务器接受仍待确认',
      );
    }
    final command = PendingRuntimeCommand(
      kind: kind,
      targetEventId: targetEventId,
      payloadFingerprint: payloadFingerprint,
      generationId: newRuntimeId('gen'),
      userClientEventId: (userClientEventId ?? '').trim().isNotEmpty
          ? userClientEventId!.trim()
          : newRuntimeId('user'),
      assistantClientEventId: (assistantClientEventId ?? '').trim().isNotEmpty
          ? assistantClientEventId!.trim()
          : newRuntimeId('assistant'),
      epochId: epochId,
      localContent: localContent,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _pendingCommandPrefsKey,
      jsonEncode(command.toJson()),
    );
    await prepareGeneration(
      generationId: command.generationId,
      userClientEventId: command.userClientEventId,
      assistantClientEventId: command.assistantClientEventId,
    );
    return command;
  }

  Future<PendingRuntimeCommand?> loadPendingCommand() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingCommandPrefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PendingRuntimeCommand.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPendingCommand({String? generationId}) async {
    final existing = await loadPendingCommand();
    if (generationId != null &&
        existing != null &&
        existing.generationId != generationId) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingCommandPrefsKey);
  }

  Future<void> startChat({
    required Map<String, dynamic> body,
    required String userClientEventId,
    required String assistantClientEventId,
    required RuntimeEventApplier onEvent,
    String? generationId,
  }) async {
    final requestedGenerationId = (generationId ?? '').trim().isNotEmpty
        ? generationId!.trim()
        : (body['generation_id'] ?? '').toString().trim().isNotEmpty
        ? body['generation_id'].toString().trim()
        : newRuntimeId('gen');
    final existing = _cursor ?? await loadCursor();
    final sameActiveGeneration =
        existing != null &&
        !existing.terminal &&
        existing.generationId == requestedGenerationId;
    if (existing != null && !existing.terminal && !sameActiveGeneration) {
      throw const RuntimeException(
        'generation_already_active',
        '已有一轮生成仍在服务器运行',
      );
    }
    if (existing != null && existing.terminal) await clearCursor();
    if (!sameActiveGeneration) _appliedSeqs.clear();

    final requestBody = <String, dynamic>{
      ...body,
      'client_event_id': userClientEventId,
      'generation_id': requestedGenerationId,
      'request_id': requestedGenerationId,
    };
    await prepareGeneration(
      generationId: requestedGenerationId,
      userClientEventId: userClientEventId,
      assistantClientEventId: assistantClientEventId,
    );

    final maxPostAttempts = max(1, startPostAttempts);
    for (var postAttempt = 0; postAttempt < maxPostAttempts; postAttempt++) {
      final request = http.Request('POST', Uri.parse(ChatApi.chatUrl))
        ..headers.addAll(
          ChatApi.authHeaders({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          }),
        )
        ..body = jsonEncode(requestBody);
      final client = http.Client();
      try {
        final response = await client
            .send(request)
            .timeout(responseHeaderTimeout);
        if (response.statusCode != 200) {
          if (!_isTransientResumeStatus(response.statusCode)) {
            final text = await response.stream
                .timeout(bodyIdleTimeout)
                .transform(utf8.decoder)
                .join();
            await clearCursor(generationId: requestedGenerationId);
            throw RuntimeException(
              'chat_start_failed',
              '服务器返回 ${response.statusCode}: ${text.substring(0, text.length > 200 ? 200 : text.length)}',
            );
          }
        } else {
          _streamClients.add(client);
          final responseGenerationId = response.headers['x-generation-id']
              ?.trim();
          final acceptedGenerationId =
              (responseGenerationId != null && responseGenerationId.isNotEmpty)
              ? responseGenerationId
              : requestedGenerationId;
          if (acceptedGenerationId != requestedGenerationId) {
            await clearCursor(generationId: requestedGenerationId);
            throw const RuntimeException(
              'generation_identity_mismatch',
              '服务器返回了不同的 generation_id',
            );
          }
          final current = _cursor ?? await loadCursor();
          await _saveCursor(
            GenerationCursor(
              threadId: 'main',
              generationId: acceptedGenerationId,
              lastSeq: current?.generationId == acceptedGenerationId
                  ? current!.lastSeq
                  : 0,
              status: GenerationTerminalStatus.running,
              userClientEventId: userClientEventId,
              assistantClientEventId: assistantClientEventId,
            ),
          );
          await _consumeResponse(
            response,
            onEvent,
            expectedGenerationId: acceptedGenerationId,
          );
        }
      } on SocketException {
        // Acceptance is uncertain. Reconcile by GET before any retry.
      } on HttpException {
        // Same reconciliation rule as SocketException.
      } on http.ClientException {
        // Same reconciliation rule as SocketException.
      } on TimeoutException {
        // Header/body silence is transient once the durable identity exists.
      } on RuntimeException catch (error) {
        if (_cursor == null || error.code != 'device_tool_report_failed') {
          rethrow;
        }
      } finally {
        _streamClients.remove(client);
        client.close();
      }

      final current = _cursor;
      if (current == null ||
          current.terminal ||
          current.generationId != requestedGenerationId) {
        return;
      }
      try {
        await resume(onEvent: onEvent);
        return;
      } on RuntimeException catch (error) {
        final canReplaySameCommand =
            error.code == 'generation_not_accepted' &&
            postAttempt + 1 < maxPostAttempts;
        if (!canReplaySameCommand) rethrow;
        // Mobile networks can deliver a large POST tens of seconds late while
        // tiny reconciliation GETs already return 404. Re-POST exactly the
        // same durable command identity; canonical user + generation registry
        // are idempotent for this tuple, so a late original request cannot
        // create a second logical message.
      }
    }
  }

  /// Subscribe to a generation that was already created by a canonical server
  /// command (edit/regenerate). The command response itself is JSON, so replay
  /// must always start from seq 0 even when the server already reports terminal.
  Future<void> attachGeneration({
    required String generationId,
    required String userClientEventId,
    required String assistantClientEventId,
    required RuntimeEventApplier onEvent,
    String threadId = 'main',
  }) async {
    final cleanGenerationId = generationId.trim();
    if (cleanGenerationId.isEmpty) {
      throw const RuntimeException(
        'generation_id_missing',
        '服务器没有返回 generation_id',
      );
    }

    final existing = _cursor ?? await loadCursor();
    if (existing != null && !existing.terminal) {
      if (existing.generationId != cleanGenerationId) {
        throw const RuntimeException(
          'generation_already_active',
          '已有一轮生成仍在服务器运行',
        );
      }
      await _saveCursor(
        existing.copyWith(
          userClientEventId: userClientEventId,
          assistantClientEventId: assistantClientEventId,
        ),
      );
      await resume(onEvent: onEvent);
      return;
    }
    if (existing != null) await clearCursor();

    _appliedSeqs.clear();
    await _saveCursor(
      GenerationCursor(
        threadId: threadId,
        generationId: cleanGenerationId,
        lastSeq: 0,
        status: GenerationTerminalStatus.running,
        userClientEventId: userClientEventId,
        assistantClientEventId: assistantClientEventId,
      ),
    );
    await resume(onEvent: onEvent);
  }

  Future<void> resume({required RuntimeEventApplier onEvent}) {
    final active = _resumeFuture;
    if (active != null) return active;

    late final Future<void> operation;
    operation = _resumeLoop(onEvent).whenComplete(() {
      if (identical(_resumeFuture, operation)) _resumeFuture = null;
    });
    _resumeFuture = operation;
    return operation;
  }

  Future<void> _resumeLoop(RuntimeEventApplier onEvent) async {
    var retryDelay = initialRetryDelay;
    var notFoundResponses = 0;
    String? boundGenerationId;
    while (true) {
      final existing = _cursor ?? await loadCursor();
      if (existing == null || existing.terminal) return;
      boundGenerationId ??= existing.generationId;
      if (existing.generationId != boundGenerationId) return;
      final uri = Uri.parse(
        ServerConfig.runtimeUrl(
          '/generations/${Uri.encodeComponent(existing.generationId)}/events',
        ),
      ).replace(queryParameters: {'after_seq': existing.lastSeq.toString()});
      final request = http.Request('GET', uri)
        ..headers.addAll(ChatApi.authHeaders({'Accept': 'text/event-stream'}));
      final client = http.Client();
      _streamClients.add(client);
      final wakeVersion = _wakeVersion;
      try {
        final response = await client
            .send(request)
            .timeout(responseHeaderTimeout);
        final responseGenerationId = response.headers['x-generation-id']
            ?.trim();
        if (responseGenerationId != null &&
            responseGenerationId.isNotEmpty &&
            responseGenerationId != existing.generationId) {
          throw const RuntimeException(
            'generation_identity_mismatch',
            '恢复流返回了不同的 generation_id',
          );
        }
        if (response.statusCode == 404) {
          notFoundResponses += 1;
          if (notFoundResponses > 2) {
            throw const RuntimeException(
              'generation_not_accepted',
              '这条消息没有被服务器接收，可以重试',
            );
          }
          // POST 已发出但服务端刚完成持久化时，紧接着的 GET
          // 可能短暂看到 404。只做有界重试，不重发用户消息。
        } else if (response.statusCode == 410) {
          notFoundResponses = 0;
          final outcome = await _applyCanonicalReplaySnapshot(
            response,
            existing,
            onEvent,
          );
          if (outcome == _ReplaySnapshotOutcome.terminalApplied) {
            return;
          }
          if (outcome == _ReplaySnapshotOutcome.unavailable) {
            await _saveCursor(
              existing.copyWith(
                status: GenerationTerminalStatus.replayUnavailable,
              ),
            );
            return;
          }
          // 410 证明 generation 已被接收；非终态 snapshot 只是
          // task/event 刚建立时的窗口，继续 GET 而不提示用户重发。
        } else if (_isTransientResumeStatus(response.statusCode)) {
          notFoundResponses = 0;
          // Closing the client below abandons this transient response body.
        } else {
          notFoundResponses = 0;
          if (response.statusCode != 200) {
            throw RuntimeException(
              'generation_resume_failed',
              '恢复生成失败：${response.statusCode}',
            );
          }
          await _consumeResponse(
            response,
            onEvent,
            expectedGenerationId: existing.generationId,
            onSequenceApplied: () => retryDelay = initialRetryDelay,
          );
        }
      } on SocketException {
        // generation 已有 durable cursor；网络断开只重连，不重发 user。
      } on HttpException {
        // 同上。
      } on http.ClientException {
        // 同上。
      } on TimeoutException {
        // 半开 SSE 长时间无数据时主动换一条连接，generation 仍由服务端持有。
      } on RuntimeException catch (error) {
        if (error.code != 'device_tool_report_failed') rethrow;
      } finally {
        _streamClients.remove(client);
        client.close();
      }

      final current = _cursor;
      if (current == null ||
          current.terminal ||
          current.generationId != boundGenerationId) {
        return;
      }
      if (_wakeVersion != wakeVersion) continue;
      await Future<void>.delayed(retryDelay);
      final nextMs = min(
        retryDelay.inMilliseconds * 2,
        maxRetryDelay.inMilliseconds,
      );
      retryDelay = Duration(milliseconds: nextMs);
    }
  }

  Future<_ReplaySnapshotOutcome> _applyCanonicalReplaySnapshot(
    http.StreamedResponse response,
    GenerationCursor cursor,
    RuntimeEventApplier onEvent,
  ) async {
    final body = await response.stream
        .timeout(bodyIdleTimeout)
        .transform(utf8.decoder)
        .join();
    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        payload = decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      return _ReplaySnapshotOutcome.unavailable;
    }
    final rawSnapshot = payload?['canonical_generation'];
    final snapshot = rawSnapshot is Map
        ? rawSnapshot.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final rawLifecycle = snapshot['lifecycle'];
    final lifecycle = rawLifecycle is Map
        ? rawLifecycle.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final rawStatus = (lifecycle['status'] ?? payload?['status'] ?? '')
        .toString()
        .trim();
    final status = generationStatusFromString(rawStatus);
    final terminal =
        lifecycle['terminal'] == true ||
        status == GenerationTerminalStatus.completed ||
        status == GenerationTerminalStatus.failed ||
        status == GenerationTerminalStatus.cancelled;
    if (!terminal) {
      return rawStatus == 'running' || rawStatus == 'waiting_tool'
          ? _ReplaySnapshotOutcome.acceptedNonTerminal
          : _ReplaySnapshotOutcome.unavailable;
    }

    final rawReconciliation = snapshot['reconciliation'];
    final reconciliation = rawReconciliation is Map
        ? rawReconciliation.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final canonicalEvent = reconciliation['canonical_event'];
    final terminalReason = (lifecycle['terminal_reason'] ?? '').toString();
    final event = RuntimeSseEvent(
      seq: null,
      payloads: [
        if (canonicalEvent is Map)
          jsonEncode({
            'type': 'canonical_generation_snapshot',
            'event': canonicalEvent,
          }),
        jsonEncode({
          'type': 'generation_terminal',
          'status': rawStatus,
          if (status == GenerationTerminalStatus.failed &&
              terminalReason.isNotEmpty)
            'error_code': terminalReason,
        }),
      ],
    );
    await onEvent(event, cursor);
    await clearCursor(generationId: cursor.generationId);
    return _ReplaySnapshotOutcome.terminalApplied;
  }

  Future<CancelGenerationOutcome> cancelActive({
    required String visibleContent,
    required List<Map<String, dynamic>> visibleParts,
    String? generationId,
  }) async {
    final existing = _cursor ?? await loadCursor();
    final explicitGenerationId = (generationId ?? '').trim();
    final targetGenerationId = explicitGenerationId.isNotEmpty
        ? explicitGenerationId
        : existing?.generationId;
    if (targetGenerationId == null || targetGenerationId.isEmpty) {
      return CancelGenerationOutcome.alreadyTerminal;
    }
    final targetCursor = existing?.generationId == targetGenerationId
        ? existing
        : null;
    if (targetCursor != null && targetCursor.terminal) {
      return targetCursor.status == GenerationTerminalStatus.replayUnavailable
          ? CancelGenerationOutcome.replayUnavailable
          : CancelGenerationOutcome.alreadyTerminal;
    }

    final client = http.Client();
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse(
                ServerConfig.runtimeUrl(
                  '/generations/${Uri.encodeComponent(targetGenerationId)}/cancel',
                ),
              ),
            )
            ..headers.addAll(
              ChatApi.authHeaders({'Content-Type': 'application/json'}),
            )
            ..body = jsonEncode({
              'visible_content': visibleContent,
              'visible_parts': visibleParts,
            });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 8));
      final body = await response.stream.bytesToString();
      if (response.statusCode == 200) {
        final status = _statusFromJsonBody(body);
        final reconciled = _boolFromJsonBody(body, 'reconciled');
        await clearCursor(generationId: targetGenerationId);
        if (reconciled && status != GenerationTerminalStatus.cancelled) {
          return CancelGenerationOutcome.reconciled;
        }
        return CancelGenerationOutcome.cancelled;
      }
      if (response.statusCode == 202) {
        // cancel_requested 只是服务端接受了取消请求；保留 cursor，让 controller
        // 继续订阅同一个 generation，直到真正的 cancelled terminal event 到达。
        return CancelGenerationOutcome.cancelled;
      }
      if (response.statusCode == 404 || response.statusCode == 410) {
        final status = _statusFromJsonBody(body);
        if (status == GenerationTerminalStatus.cancelled) {
          await clearCursor(generationId: targetGenerationId);
          return CancelGenerationOutcome.cancelled;
        }
        // Legacy callers without an explicit identity still own the current
        // cursor, so preserve the old replay-unavailable marker. Explicit
        // cancel callers may already have started a replacement generation;
        // never overwrite that newer cursor with stale status.
        if (explicitGenerationId.isEmpty && targetCursor != null) {
          await _saveCursor(
            targetCursor.copyWith(
              status: GenerationTerminalStatus.replayUnavailable,
            ),
          );
        }
        return CancelGenerationOutcome.replayUnavailable;
      }
      if (response.statusCode == 409) {
        final status = _statusFromJsonBody(body);
        if (status == GenerationTerminalStatus.cancelled) {
          await clearCursor(generationId: targetGenerationId);
          return CancelGenerationOutcome.cancelled;
        }
        return CancelGenerationOutcome.alreadyTerminal;
      }
      return CancelGenerationOutcome.failed;
    } on TimeoutException {
      return CancelGenerationOutcome.failed;
    } on SocketException {
      return CancelGenerationOutcome.failed;
    } on HttpException {
      return CancelGenerationOutcome.failed;
    } on http.ClientException {
      return CancelGenerationOutcome.failed;
    } finally {
      client.close();
    }
  }

  Future<bool> _consumeResponse(
    http.StreamedResponse response,
    RuntimeEventApplier onEvent, {
    required String expectedGenerationId,
    VoidCallback? onSequenceApplied,
  }) async {
    return _consumeLines(
      response.stream
          .timeout(bodyIdleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
      onEvent,
      expectedGenerationId: expectedGenerationId,
      onSequenceApplied: onSequenceApplied,
    );
  }

  bool _isTransientResumeStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500;
  }

  Future<bool> _consumeLines(
    Stream<String> lines,
    RuntimeEventApplier onEvent, {
    required String expectedGenerationId,
    VoidCallback? onSequenceApplied,
  }) async {
    var sawDone = false;
    await for (final event in lines.transform(_parser)) {
      final current = _cursor;
      if (current == null || current.generationId != expectedGenerationId) {
        return sawDone;
      }
      final seq = event.seq;
      if (seq != null &&
          (seq <= current.lastSeq || _appliedSeqs.contains(seq))) {
        continue;
      }
      final status = _terminalStatusFromEvent(event) ?? current.status;
      await onEvent(event, current);
      final advanced = current.copyWith(
        lastSeq: seq == null ? current.lastSeq : max(current.lastSeq, seq),
        status: status,
      );
      if (advanced.terminal) {
        await _saveCursor(advanced);
        if (seq != null) onSequenceApplied?.call();
        await clearCursor();
      } else {
        await _saveCursor(advanced);
        if (seq != null) {
          _appliedSeqs.add(seq);
          onSequenceApplied?.call();
        }
      }
      if (event.hasDonePayload) sawDone = true;
    }
    return sawDone;
  }

  GenerationTerminalStatus? _terminalStatusFromEvent(RuntimeSseEvent event) {
    for (final json in event.jsonPayloads) {
      final type = json['type']?.toString();
      if (type == 'generation_terminal') {
        return generationStatusFromString(json['status']?.toString());
      }
      if (type == 'generation_cancelled') {
        return GenerationTerminalStatus.cancelled;
      }
      if (type == 'chat_error') return GenerationTerminalStatus.failed;
    }
    return null;
  }

  GenerationTerminalStatus? _statusFromJsonBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return generationStatusFromString(decoded['status']?.toString());
      }
    } catch (_) {}
    return null;
  }

  bool _boolFromJsonBody(String body, String key) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded[key] == true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static String get cursorPrefsKeyForTesting => _cursorPrefsKey;

  @visibleForTesting
  static String get pendingCommandPrefsKeyForTesting => _pendingCommandPrefsKey;
}

class RuntimeException implements Exception {
  const RuntimeException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
