import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../models/message.dart';
import 'chat_api.dart';
import 'chat_store.dart';
import 'device_capability_bridge.dart';
import 'new_message_notifier.dart';
import 'runtime_event_client.dart';

class ChatRuntimeController extends ChangeNotifier with WidgetsBindingObserver {
  ChatRuntimeController._();

  static final ChatRuntimeController instance = ChatRuntimeController._();

  List<ChatMessage>? _messages;
  ChatMessage? _activeReply;
  final ShellTagStripper _shellStripper = ShellTagStripper();
  bool _sending = false;
  bool _commandStarting = false;
  bool _busy = false;
  int _busyRound = 0;
  bool _deviceRunning = false;
  bool _partsMode = false;
  Future<List<ChatMessage>>? _messagesLoading;
  Future<void>? _resumeFuture;
  Future<CancelGenerationOutcome>? _stopFuture;
  bool _started = false;
  String? _cancelRequestedGenerationId;

  /// 流式 UI 合帧窗口：同一窗口内的多个 delta 只触发一次 listener。
  /// 它只负责 UI 通知频率，与落盘 checkpoint 分开，避免高频 notify
  /// 反复放大 ChatPage 的 setState / presentation capture。
  static const Duration streamUiCoalesceWindow = Duration(milliseconds: 16);

  /// Reasoning 常由 Provider 以 1~3 个字的小 delta 高频推送。canonical
  /// message 仍逐 delta 立即累积，但 UI 只按这个窗口合帧，避免展开思考链时
  /// Selectable/layout/scroll 每个 token 都重建，看起来又慢又卡。
  static const Duration reasoningUiCoalesceWindow = Duration(milliseconds: 80);

  /// 流式 checkpoint 落盘上限：长时间连续流式时，未落盘内容最多滞后这么久。
  /// 终态、切后台、页面 dispose 都不受它影响，一律立即 flush。
  static const Duration streamCheckpointInterval = Duration(milliseconds: 400);

  Timer? _streamUiTimer;
  Duration? _streamUiWindow;
  Timer? _streamCheckpointTimer;
  Future<void>? _streamCheckpointWrite;
  Future<void>? _streamFlushFuture;
  List<ChatMessage>? _pendingCheckpointMessages;
  String? _pendingCheckpointGenerationId;

  bool get isSending => _sending || _commandStarting;
  bool get isStopping => _stopFuture != null;
  bool get commandStarting => _commandStarting;
  bool get busy => _busy;
  int get busyRound => _busyRound;
  bool get deviceRunning => _deviceRunning;
  ChatMessage? get activeReply => _activeReply;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(resumeActiveGeneration());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // 切后台/失焦：先把已经收到但还没 checkpoint 的流式内容落盘，
      // 不允许内存里更新的正文只活在内存里。
      unawaited(flushPendingStreamingWork());
      return;
    }
    RuntimeEventClient.instance.wakeReconnect();
    if (!_sending && !_commandStarting) {
      unawaited(resumeActiveGeneration());
    }
  }

  void bindMessages(List<ChatMessage> messages) {
    _messages = messages;
  }

  void unbindMessages(List<ChatMessage> messages) {
    if (!identical(_messages, messages)) return;
    // 页面 dispose / 换绑窗口：同样先把尚未 checkpoint 的流式内容落盘。
    unawaited(flushPendingStreamingWork());
    _messages = null;
  }

  @override
  void dispose() {
    unawaited(flushPendingStreamingWork());
    super.dispose();
  }

  Future<void> resumeActiveGeneration() {
    final active = _resumeFuture;
    if (active != null) return active;

    late final Future<void> operation;
    operation = _resumeActiveGeneration().whenComplete(() {
      if (identical(_resumeFuture, operation)) _resumeFuture = null;
    });
    _resumeFuture = operation;
    return operation;
  }

  Future<void> _resumeActiveGeneration() async {
    var cursor = await RuntimeEventClient.instance.loadCursor();
    if (cursor == null) {
      cursor = await _recoverOrphanLocalSendCursor();
      if (cursor == null) return;
    }
    if (cursor.terminal) {
      if (cursor.status == GenerationTerminalStatus.replayUnavailable) {
        final messages = await _ensureMessages();
        _activeReply = _findMessageByClientId(cursor.assistantClientEventId);
        if (_activeReply == null) {
          final user = _findMessageByClientId(cursor.userClientEventId);
          if (user != null) {
            user
              ..sendFailed = true
              ..sendError = '上次回复的服务器状态无法确认（replay_unavailable）';
            await _save(messages);
          }
        } else {
          await _settleReplayUnavailable();
        }
        await RuntimeEventClient.instance.clearCursor(
          generationId: cursor.generationId,
        );
        await RuntimeEventClient.instance.clearPendingCommand(
          generationId: cursor.generationId,
        );
        _notify();
        return;
      }
      await RuntimeEventClient.instance.clearCursor();
      await RuntimeEventClient.instance.clearPendingCommand(
        generationId: cursor.generationId,
      );
      return;
    }
    final messages = await _ensureMessages();
    _activeReply = _findMessageByClientId(cursor.assistantClientEventId);
    _partsMode = _activeReply?.parts.isNotEmpty ?? false;
    final resumeCancellation =
        _activeReply?.runtimeStatus == 'cancel_requested';
    final localStatus = generationStatusFromString(_activeReply?.runtimeStatus);
    if (_activeReply != null && generationStatusIsTerminal(localStatus)) {
      await RuntimeEventClient.instance.clearCursor();
      await RuntimeEventClient.instance.clearPendingCommand(
        generationId: cursor.generationId,
      );
      _sending = false;
      _busy = false;
      _busyRound = 0;
      _deviceRunning = false;
      _activeReply = null;
      _notify();
      return;
    }
    if (_activeReply == null) {
      final reply = ChatMessage(
        role: 'assistant',
        content: '',
        clientEventId: cursor.assistantClientEventId,
        generationId: cursor.generationId,
        runtimeSeq: cursor.lastSeq,
        runtimeStatus: generationStatusToString(cursor.status),
      );
      messages.add(reply);
      _activeReply = reply;
      await _save(messages);
    }
    _sending = true;
    _notify();
    if (resumeCancellation) {
      _cancelRequestedGenerationId = cursor.generationId;
      await stopActiveGeneration();
      return;
    }
    try {
      // A durable generation identity is sufficient proof that reconciliation
      // must use replay, including when no event has reached this device yet.
      await RuntimeEventClient.instance.resume(onEvent: _applyRuntimeEvent);
      final after = RuntimeEventClient.instance.cursor;
      if (after?.status == GenerationTerminalStatus.replayUnavailable) {
        await _settleReplayUnavailable();
      }
    } on RuntimeException catch (e) {
      await _settleReplayFailure(e.message, code: e.code);
    } catch (e) {
      await _settleReplayFailure('恢复生成失败：$e', code: 'resume_failed');
    }
  }

  Future<GenerationCursor?> _recoverOrphanLocalSendCursor() async {
    final messages = await _ensureMessages();
    if (messages.isEmpty) return null;

    ChatMessage? reply;
    ChatMessage? user;
    final last = messages.last;
    if (last.role == 'assistant' &&
        !_replyHasVisibleOutput(last) &&
        !generationStatusIsTerminal(
          generationStatusFromString(last.runtimeStatus),
        )) {
      reply = last;
      user = _findPreviousUser(last);
    } else if (last.role == 'user') {
      user = last;
    } else {
      return null;
    }
    if (user == null || user.sendFailed || user.content.trim().isEmpty) {
      return null;
    }

    final generationId = (reply?.generationId ?? user.generationId ?? '')
        .trim();
    if (generationId.isEmpty) {
      if (reply != null) {
        messages.remove(reply);
      }
      user
        ..sendFailed = true
        ..sendError = '这条消息没有完成发送（local_send_identity_missing）';
      await _save(messages);
      _notify();
      return null;
    }

    user.clientEventId ??= RuntimeEventClient.newRuntimeId('user-recover');
    reply ??= ChatMessage(role: 'assistant', content: '');
    reply.clientEventId ??= RuntimeEventClient.newRuntimeId(
      'assistant-recover',
    );
    user.generationId = generationId;
    reply.generationId = generationId;
    if (!messages.contains(reply)) messages.add(reply);
    _activeReply = reply;
    await RuntimeEventClient.instance.prepareGeneration(
      generationId: generationId,
      userClientEventId: user.clientEventId!,
      assistantClientEventId: reply.clientEventId!,
    );
    await _save(messages);
    return RuntimeEventClient.instance.cursor;
  }

  Future<void> startChat({
    required List<ChatMessage> messages,
    required List<ChatMessage> history,
    required ChatMessage sentMessage,
    required ChatMessage reply,
    Future<Map<String, dynamic>> Function(List<ChatMessage>)?
    requestBodyBuilder,
    Future<void> Function(List<ChatMessage>)? messageSaver,
  }) async {
    bindMessages(messages);
    sentMessage.clientEventId ??= RuntimeEventClient.newRuntimeId('user');
    sentMessage.kind ??= 'user';
    reply.clientEventId ??= RuntimeEventClient.newRuntimeId('assistant');
    reply.kind ??= 'assistant';
    final generationId =
        (sentMessage.generationId ?? reply.generationId ?? '').trim().isNotEmpty
        ? (sentMessage.generationId ?? reply.generationId)!.trim()
        : RuntimeEventClient.newRuntimeId('gen');
    sentMessage.generationId = generationId;
    reply.generationId = generationId;
    _activeReply = reply;
    _cancelRequestedGenerationId = null;
    _sending = true;
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _partsMode = false;
    _notify();
    try {
      // Persist the recovery identity before any local file I/O or request-body
      // preparation can stall. A visible local bubble must never exist for
      // minutes without a durable generation identity behind it.
      await RuntimeEventClient.instance.prepareGeneration(
        generationId: generationId,
        userClientEventId: sentMessage.clientEventId!,
        assistantClientEventId: reply.clientEventId!,
      );
      await (messageSaver ?? _save)(messages);
      final body = await (requestBodyBuilder ?? ChatApi.buildChatRequestBody)(
        history,
      );
      await RuntimeEventClient.instance.startChat(
        body: body,
        userClientEventId: sentMessage.clientEventId!,
        assistantClientEventId: reply.clientEventId!,
        onEvent: _applyRuntimeEvent,
        generationId: generationId,
      );
      final after = RuntimeEventClient.instance.cursor;
      final acceptedGenerationId = after?.generationId;
      if (acceptedGenerationId != null && acceptedGenerationId.isNotEmpty) {
        sentMessage.generationId = acceptedGenerationId;
        reply.generationId = acceptedGenerationId;
      }
      if (after?.status == GenerationTerminalStatus.replayUnavailable) {
        await _settleReplayUnavailable();
      }
    } on RuntimeException catch (e) {
      await _failStartedMessage(sentMessage, reply, e.message, code: e.code);
    } catch (e) {
      await _failStartedMessage(sentMessage, reply, '连接失败: $e');
    }
  }

  Future<String?> startCanonicalEdit({
    required List<ChatMessage> messages,
    required ChatMessage target,
    required String editedText,
  }) async {
    if (isSending) return '已有一轮回复正在运行';
    bindMessages(messages);
    _commandStarting = true;
    _notify();
    final existingCursor =
        RuntimeEventClient.instance.cursor ??
        await RuntimeEventClient.instance.loadCursor();
    final pendingCommand = await RuntimeEventClient.instance
        .loadPendingCommand();
    if (existingCursor != null &&
        !existingCursor.terminal &&
        pendingCommand?.generationId != existingCursor.generationId) {
      _commandStarting = false;
      _notify();
      return '已有一轮回复仍在服务器运行';
    }
    if (existingCursor != null && existingCursor.terminal) {
      await RuntimeEventClient.instance.clearCursor();
    }
    final eventId = (target.eventId ?? '').trim();
    final epochId = (target.epochId ?? '').trim();
    if (eventId.isEmpty || epochId.isEmpty) {
      _commandStarting = false;
      _notify();
      return '这条消息的服务器身份不完整，当前不能安全编辑重发';
    }

    final fingerprintCandidate = _editedUserReplacement(
      target,
      editedText,
      clientEventId: 'pending-user',
      generationId: 'pending-generation',
      epochId: epochId,
    );
    final mutationContent = ChatApi.runtimeMutationContent(
      fingerprintCandidate,
    );
    late final PendingRuntimeCommand command;
    try {
      command = await RuntimeEventClient.instance.prepareMutationCommand(
        kind: 'edit',
        targetEventId: eventId,
        payloadFingerprint: mutationContent,
        epochId: epochId,
        localContent: editedText,
      );
    } on RuntimeException catch (error) {
      _commandStarting = false;
      _notify();
      return error.message;
    }
    final generationId = command.generationId;
    final replacementClientId = command.userClientEventId;
    final assistantClientId = command.assistantClientEventId;
    final replacement = _editedUserReplacement(
      target,
      editedText,
      clientEventId: replacementClientId,
      generationId: generationId,
      epochId: epochId,
    );
    final response = await ChatApi.editRuntimeEvent(
      eventId: eventId,
      epochId: epochId,
      generationId: generationId,
      clientEventId: replacementClientId,
      requestId: generationId,
      content: mutationContent,
    );
    if (response == null || response['ok'] != true) {
      _commandStarting = false;
      _notify();
      return '服务器暂时没能编辑重发，对话没有改动';
    }
    final returnedGeneration = _responseString(response, 'generation_id');
    final returnedUser = _responseString(response, 'user_event_id');
    final returnedEpoch = _responseString(response, 'epoch_id');
    if (returnedGeneration != generationId ||
        returnedUser.isEmpty ||
        returnedEpoch.isEmpty) {
      _commandStarting = false;
      _notify();
      return '服务器返回的编辑重发身份不完整，请稍后再试';
    }
    replacement
      ..eventId = returnedUser
      ..generationId = returnedGeneration
      ..epochId = returnedEpoch;
    final event = response['event'];
    if (event is Map) {
      replacement.rawEventId = _jsonInt(event['raw_event_id']);
    }
    final branch = response['active_branch'];
    if (branch is! List) {
      final targetIndex = messages.indexOf(target);
      if (targetIndex >= 0) {
        messages
          ..removeRange(targetIndex, messages.length)
          ..add(replacement);
      }
    }
    final reply = ChatMessage(
      role: 'assistant',
      content: '',
      clientEventId: assistantClientId,
      generationId: returnedGeneration,
      epochId: returnedEpoch,
      kind: 'assistant',
      runtimeStatus: 'running',
    );
    unawaited(
      attachCommandGeneration(
        messages: messages,
        userMessage: replacement,
        reply: reply,
        generationId: returnedGeneration,
        epochId: returnedEpoch,
        activeBranch: branch is List ? branch : null,
      ).whenComplete(
        () => RuntimeEventClient.instance.clearPendingCommand(
          generationId: returnedGeneration,
        ),
      ),
    );
    return null;
  }

  Future<String?> startCanonicalRegenerate({
    required List<ChatMessage> messages,
    required ChatMessage userMessage,
  }) async {
    if (isSending) return '已有一轮回复正在运行';
    bindMessages(messages);
    _commandStarting = true;
    _notify();
    final existingCursor =
        RuntimeEventClient.instance.cursor ??
        await RuntimeEventClient.instance.loadCursor();
    final pendingCommand = await RuntimeEventClient.instance
        .loadPendingCommand();
    if (existingCursor != null &&
        !existingCursor.terminal &&
        pendingCommand?.generationId != existingCursor.generationId) {
      _commandStarting = false;
      _notify();
      return '已有一轮回复仍在服务器运行';
    }
    if (existingCursor != null && existingCursor.terminal) {
      await RuntimeEventClient.instance.clearCursor();
    }
    final eventId = (userMessage.eventId ?? '').trim();
    final epochId = (userMessage.epochId ?? '').trim();
    if (eventId.isEmpty || epochId.isEmpty) {
      _commandStarting = false;
      _notify();
      return '这条消息的服务器身份不完整，当前不能安全重新生成';
    }
    late final PendingRuntimeCommand command;
    try {
      command = await RuntimeEventClient.instance.prepareMutationCommand(
        kind: 'regenerate',
        targetEventId: eventId,
        payloadFingerprint: '$eventId\n$epochId',
        epochId: epochId,
        userClientEventId:
            userMessage.clientEventId ??
            RuntimeEventClient.newRuntimeId('user'),
      );
    } on RuntimeException catch (error) {
      _commandStarting = false;
      _notify();
      return error.message;
    }
    final generationId = command.generationId;
    final assistantClientId = command.assistantClientEventId;
    final response = await ChatApi.regenerateRuntimeEvent(
      userEventId: eventId,
      epochId: epochId,
      generationId: generationId,
    );
    if (response == null || response['ok'] != true) {
      _commandStarting = false;
      _notify();
      return '服务器暂时没能开始重新生成，对话没有改动';
    }
    final returnedGeneration = _responseString(response, 'generation_id');
    final returnedUser = _responseString(response, 'user_event_id');
    final returnedEpoch = _responseString(response, 'epoch_id');
    if (returnedGeneration != generationId ||
        returnedUser != eventId ||
        returnedEpoch.isEmpty) {
      _commandStarting = false;
      _notify();
      return '服务器返回的重新生成身份不完整，请稍后再试';
    }
    userMessage
      ..generationId = returnedGeneration
      ..epochId = returnedEpoch;
    final branch = response['active_branch'];
    if (branch is! List) {
      final userIndex = messages.indexOf(userMessage);
      if (userIndex >= 0) {
        for (var i = messages.length - 1; i > userIndex; i--) {
          if (messages[i].role == 'assistant') messages.removeAt(i);
        }
      }
    }
    final reply = ChatMessage(
      role: 'assistant',
      content: '',
      clientEventId: assistantClientId,
      generationId: returnedGeneration,
      epochId: returnedEpoch,
      kind: 'assistant',
      runtimeStatus: 'running',
    );
    unawaited(
      attachCommandGeneration(
        messages: messages,
        userMessage: userMessage,
        reply: reply,
        generationId: returnedGeneration,
        epochId: returnedEpoch,
        activeBranch: branch is List ? branch : null,
      ).whenComplete(
        () => RuntimeEventClient.instance.clearPendingCommand(
          generationId: returnedGeneration,
        ),
      ),
    );
    return null;
  }

  /// Follow a generation that a canonical edit/regenerate command has already
  /// started on the server. This path never sends /chat again.
  Future<void> attachCommandGeneration({
    required List<ChatMessage> messages,
    required ChatMessage userMessage,
    required ChatMessage reply,
    required String generationId,
    String? epochId,
    List<dynamic>? activeBranch,
  }) async {
    bindMessages(messages);
    userMessage.clientEventId ??= RuntimeEventClient.newRuntimeId('user');
    reply.clientEventId ??= RuntimeEventClient.newRuntimeId('assistant');
    userMessage
      ..generationId = generationId
      ..epochId = epochId ?? userMessage.epochId;
    reply
      ..generationId = generationId
      ..epochId = epochId ?? reply.epochId
      ..runtimeStatus = 'running';

    if (activeBranch != null && activeBranch.isNotEmpty) {
      _reconcileCanonicalBranch(messages, activeBranch, userMessage);
    }
    if (!messages.contains(reply)) messages.add(reply);

    _activeReply = reply;
    _cancelRequestedGenerationId = null;
    _sending = true;
    _commandStarting = false;
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _partsMode = false;
    _notify();
    await _save(messages);
    try {
      await RuntimeEventClient.instance.attachGeneration(
        generationId: generationId,
        userClientEventId: userMessage.clientEventId!,
        assistantClientEventId: reply.clientEventId!,
        onEvent: _applyRuntimeEvent,
      );
      final after = RuntimeEventClient.instance.cursor;
      if (after?.status == GenerationTerminalStatus.replayUnavailable) {
        await _settleReplayUnavailable();
      }
    } on RuntimeException catch (e) {
      await _failAttachedGeneration(reply, e.message, code: e.code);
    } catch (e) {
      await _failAttachedGeneration(
        reply,
        '恢复这轮回复失败：$e',
        code: 'generation_resume_failed',
      );
    }
  }

  Future<CancelGenerationOutcome> stopActiveGeneration({
    String? visibleContent,
    List<ChatMessagePart>? visibleParts,
  }) {
    final active = _stopFuture;
    if (active != null) return active;

    late final Future<CancelGenerationOutcome> operation;
    operation =
        _stopActiveGeneration(
          visibleContent: visibleContent,
          visibleParts: visibleParts,
        ).whenComplete(() {
          if (identical(_stopFuture, operation)) {
            _stopFuture = null;
            _notify();
          }
        });
    _stopFuture = operation;
    _notify();
    return operation;
  }

  Future<CancelGenerationOutcome> _stopActiveGeneration({
    String? visibleContent,
    List<ChatMessagePart>? visibleParts,
  }) async {
    if (!_sending) return CancelGenerationOutcome.alreadyTerminal;

    final reply = _activeReply;
    final generationId =
        reply?.generationId ?? RuntimeEventClient.instance.cursor?.generationId;
    if (generationId != null && generationId.isNotEmpty) {
      _cancelRequestedGenerationId = generationId;
    }
    if (reply != null) {
      if (visibleContent != null) reply.content = visibleContent;
      if (visibleParts != null) reply.parts = visibleParts;
      reply.runtimeStatus = 'cancel_requested';
      _partsMode = reply.parts.isNotEmpty;
    }
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _notify();
    final messages = _messages;
    if (messages != null) await _commitImmediately(messages);

    final outcome = await RuntimeEventClient.instance.cancelActive(
      generationId: generationId,
      visibleContent: visibleContent ?? reply?.content ?? '',
      visibleParts: [
        for (final part
            in visibleParts ?? reply?.parts ?? const <ChatMessagePart>[])
          part.toJson(),
      ],
    );
    if (outcome == CancelGenerationOutcome.failed) {
      return outcome;
    }
    if (outcome == CancelGenerationOutcome.replayUnavailable) {
      await _settleReplayUnavailable();
      return outcome;
    }
    if (outcome == CancelGenerationOutcome.reconciled) {
      final reply = _activeReply;
      if (reply != null) {
        reply.runtimeStatus = 'completed';
        await _finishByStatus(
          reply,
          GenerationTerminalStatus.completed,
          stopped: true,
        );
      }
      return outcome;
    }

    final cursor = RuntimeEventClient.instance.cursor;
    if (cursor != null && !cursor.terminal) {
      try {
        await RuntimeEventClient.instance.resume(onEvent: _applyRuntimeEvent);
      } on RuntimeException {
        return CancelGenerationOutcome.failed;
      } catch (_) {
        return CancelGenerationOutcome.failed;
      }
      final after = RuntimeEventClient.instance.cursor;
      if (after?.status == GenerationTerminalStatus.replayUnavailable) {
        await _settleReplayUnavailable();
        return CancelGenerationOutcome.replayUnavailable;
      }
      if (!_sending) return outcome;
    }

    // 200 cancelled / 已经取消且 runtime cursor 已清时，没有 terminal replay 可再应用；
    // 这时才由 controller 做本地 cancelled 收口。409 already-terminal 不强改状态。
    if (outcome == CancelGenerationOutcome.cancelled) {
      final reply = _activeReply;
      if (reply != null) {
        reply.runtimeStatus = 'cancelled';
        await _finishByStatus(reply, GenerationTerminalStatus.cancelled);
      } else {
        _sending = false;
        _busy = false;
        _busyRound = 0;
        _deviceRunning = false;
        _notify();
      }
    }
    return outcome;
  }

  Future<void> handlePendingItems(List<Map<String, dynamic>> items) async {
    final messages = await _ensureMessages();
    final added = <ChatMessage>[];
    for (final item in items) {
      final pendingId = (item['id'] as String? ?? '').trim();
      final eventId = item['event_id']?.toString();
      final serverClientId = item['client_event_id']?.toString();
      final localClientId =
          (serverClientId != null && serverClientId.isNotEmpty)
          ? serverClientId
          : (pendingId.isEmpty ? null : 'pending:$pendingId');
      final alreadyPresent = messages.any(
        (message) =>
            (eventId != null &&
                eventId.isNotEmpty &&
                message.eventId == eventId) ||
            (localClientId != null &&
                localClientId.isNotEmpty &&
                message.clientEventId == localClientId),
      );
      if (alreadyPresent) continue;
      final content = (item['content'] as String? ?? '').trim();
      final imageUrl = (item['imageUrl'] as String? ?? '').trim();
      final imageUrls = <String>[
        for (final url in (item['imageUrls'] as List<dynamic>? ?? const []))
          if (url is String && url.trim().isNotEmpty) url.trim(),
      ];
      final rawType = item['type']?.toString() ?? '';
      final isActivity = rawType == 'activity' || rawType == 'no_response';
      final hasVisibleContent =
          content.isNotEmpty || imageUrl.isNotEmpty || imageUrls.isNotEmpty;
      if (!hasVisibleContent) continue;
      final parts = isActivity
          ? const <ChatMessagePart>[]
          : <ChatMessagePart>[
              if (content.isNotEmpty)
                ChatMessagePart(type: ChatMessagePartType.text, text: content),
              if (imageUrl.isNotEmpty)
                ChatMessagePart(type: ChatMessagePartType.image, url: imageUrl),
              for (final url in imageUrls)
                ChatMessagePart(type: ChatMessagePartType.image, url: url),
            ];
      final message = ChatMessage(
        role: isActivity ? 'activity' : 'assistant',
        content: content,
        eventId: eventId,
        clientEventId: localClientId,
        generationId: item['generation_id']?.toString(),
        epochId: item['epoch_id']?.toString(),
        kind: rawType.isEmpty ? null : rawType,
        imageUrl: isActivity || imageUrl.isEmpty ? null : imageUrl,
        imageUrls: isActivity ? const [] : imageUrls,
        parts: parts,
      );
      messages.add(message);
      added.add(message);
    }
    if (added.isEmpty) return;
    await _save(messages);
    for (final message in added) {
      if (message.role == 'assistant' && !message.isActivity) {
        unawaited(NewMessageNotifier.instance.maybeNotify(message.content));
      }
    }
    _notify();
  }

  Future<void> appendToolDoneLabels(List<String> labels) async {
    final clean = [
      for (final label in labels)
        if (label.trim().isNotEmpty) label.trim(),
    ];
    if (clean.isEmpty) return;
    final messages = await _ensureMessages();
    for (final label in clean) {
      messages.add(ChatMessage(role: 'tool_done', content: label));
    }
    await _save(messages);
    _notify();
  }

  FutureOr<void> _applyRuntimeEvent(
    RuntimeSseEvent event,
    GenerationCursor cursor,
  ) async {
    final activeGenerationId = (_activeReply?.generationId ?? '').trim();
    if (activeGenerationId.isNotEmpty &&
        activeGenerationId != cursor.generationId) {
      return;
    }
    final messages = await _ensureMessages();
    await _materializePendingMutation(messages, cursor);
    var reply = _findMessageByClientId(cursor.assistantClientEventId);
    final active = _activeReply;
    if (reply == null &&
        active != null &&
        active.generationId == cursor.generationId &&
        active.clientEventId == cursor.assistantClientEventId) {
      reply = active;
    }
    if (reply == null) {
      reply = ChatMessage(
        role: 'assistant',
        content: '',
        clientEventId: cursor.assistantClientEventId,
        generationId: cursor.generationId,
      );
      messages.add(reply);
    }
    final eventOwnsActiveReply =
        _activeReply == null ||
        _activeReply!.generationId == cursor.generationId;
    if (eventOwnsActiveReply) _activeReply = reply;
    final eventSeq = event.seq;
    final alreadyAppliedSeq = reply.runtimeSeq ?? 0;
    if (eventSeq != null && eventSeq <= alreadyAppliedSeq) {
      return;
    }
    reply.generationId = cursor.generationId;
    final user = _findMessageByClientId(cursor.userClientEventId);
    user?.generationId = cursor.generationId;

    var appliedPayload = false;
    var streamingOnly = true;
    var reasoningOnlyStreaming = true;
    var skippedPayload = false;
    for (final payload in event.payloads) {
      if (payload.trim() == '[DONE]') continue;
      final json = RuntimeSseEvent.jsonForPayload(payload);
      if (json == null) continue;
      final type = json['type']?.toString();
      final discardingPostCancel =
          _cancelRequestedGenerationId == cursor.generationId;
      if (discardingPostCancel &&
          type != 'generation_terminal' &&
          type != 'generation_cancelled' &&
          type != 'chat_error' &&
          type != 'metadata') {
        skippedPayload = true;
        continue;
      }
      appliedPayload = true;
      final payloadIsStreaming = _payloadIsStreamingDelta(json);
      streamingOnly = streamingOnly && payloadIsStreaming;
      if (payloadIsStreaming) {
        reasoningOnlyStreaming =
            reasoningOnlyStreaming && _payloadIsReasoningDelta(json);
        // Register pending durability before mutating the in-memory message.
        // A lifecycle pause can arrive immediately after the mutation becomes
        // visible but before the normal checkpoint scheduler runs.
        _pendingCheckpointMessages = messages;
        _pendingCheckpointGenerationId = cursor.generationId;
      }
      switch (type) {
        case 'canonical_generation_snapshot':
          final rawEvent = json['event'];
          if (rawEvent is Map) {
            _applyCanonicalReplySnapshot(
              reply,
              rawEvent.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
          break;
        case 'generation_terminal':
          final status = generationStatusFromString(json['status']?.toString());
          reply
            ..runtimeSeq = eventSeq ?? cursor.lastSeq
            ..runtimeStatus = generationStatusToString(status);
          _partsMode = false;
          if (status == GenerationTerminalStatus.failed) {
            final code = (json['error_code']?.toString() ?? 'generation_failed')
                .trim();
            final message = (json['error_message']?.toString() ?? '').trim();
            await _failActiveReply(
              message.isEmpty ? '这轮回复已中断，可以直接重新发送' : message,
              code: code.isEmpty ? 'generation_failed' : code,
            );
          } else {
            await _finishByStatus(reply, status);
          }
          return;
        case 'generation_cancelled':
          reply
            ..runtimeSeq = eventSeq ?? cursor.lastSeq
            ..runtimeStatus = 'cancelled';
          _partsMode = false;
          await _finishByStatus(reply, GenerationTerminalStatus.cancelled);
          return;
        case 'part':
          _partsMode = true;
          final rawPart = json['part'];
          if (rawPart is Map) {
            _applyIncomingPart(
              reply,
              ChatMessagePart.fromJson(
                rawPart.map((key, value) => MapEntry(key.toString(), value)),
              ),
            );
          }
          break;
        case 'busy':
          _markBusy(reply, (json['round'] as num?)?.toInt() ?? 1);
          break;
        case 'interim_reply':
          if (_partsMode) break;
          final content = (json['content']?.toString() ?? '').trim();
          if (content.isNotEmpty) {
            _applyIncomingPart(
              reply,
              ChatMessagePart(type: ChatMessagePartType.text, text: content),
            );
          }
          break;
        case 'no_response':
          _partsMode = true;
          final noResponse = _replaceReplyWithNoResponse(
            messages,
            reply,
            (json['content']?.toString() ?? '').trim(),
          );
          _activeReply = noResponse;
          _sending = false;
          break;
        case 'metadata':
          _applyMetadata(json, cursor);
          break;
        case 'termux_pending':
          await _handleStreamTermux(json, cursor.generationId);
          break;
        case 'nudge_pending':
          await _handleStreamNudge(json, cursor.generationId);
          break;
        case 'image':
          if (_partsMode) break;
          final url = json['url']?.toString() ?? '';
          if (url.isNotEmpty) _appendImagePart(reply, url);
          break;
        case 'chat_error':
          reply
            ..runtimeSeq = eventSeq ?? cursor.lastSeq
            ..runtimeStatus = 'failed';
          _partsMode = false;
          await _failActiveReply(
            (json['message']?.toString() ?? '').trim().isEmpty
                ? '回复中断，请稍后重试'
                : json['message'].toString(),
            code: (json['code']?.toString() ?? 'chat_failed').trim(),
          );
          return;
        default:
          _applyLegacyDelta(reply, json);
      }
    }

    final checkpoint =
        _findMessageByClientId(cursor.assistantClientEventId) ??
        (messages.contains(reply) ? reply : null);
    if (checkpoint != null) {
      checkpoint
        ..generationId = cursor.generationId
        ..runtimeSeq = eventSeq ?? cursor.lastSeq
        ..runtimeStatus = _cancelRequestedGenerationId == cursor.generationId
            ? 'cancel_requested'
            : generationStatusToString(cursor.status);
    }
    if ((appliedPayload && streamingOnly) ||
        (!appliedPayload && skippedPayload)) {
      // 高频流式内容只更新内存里的 canonical message：UI 合帧通知，
      // 落盘降级为有上限频率的 checkpoint。
      _scheduleStreamingUiNotify(
        window: appliedPayload && streamingOnly && reasoningOnlyStreaming
            ? reasoningUiCoalesceWindow
            : streamUiCoalesceWindow,
      );
      _scheduleStreamingCheckpoint(messages, cursor.generationId);
      return;
    }
    await _commitImmediately(messages);
  }

  /// 只有正文/思考 delta 属于高频流式内容。其余 payload（busy、tool、
  /// metadata、canonical snapshot、no_response、终态…）都携带交互或身份状态，
  /// 必须立即落盘并通知 UI，不能被节流拖慢。
  bool _payloadIsStreamingDelta(Map<String, dynamic> json) {
    final type = json['type']?.toString();
    if (type == 'part') {
      final rawPart = json['part'];
      if (rawPart is! Map) return false;
      final partType = rawPart['type']?.toString();
      return partType == null ||
          partType.isEmpty ||
          partType == 'text' ||
          partType == 'reasoning';
    }
    if (type == 'interim_reply') return true;
    if (type != null && type.isNotEmpty) return false;
    // 无 type 的 legacy chunk；带 usage 的收尾片仍按关键状态立即落盘。
    final usage = json['usage'];
    return !(usage is Map && usage.isNotEmpty);
  }

  bool _payloadIsReasoningDelta(Map<String, dynamic> json) {
    if (json['type']?.toString() == 'part') {
      final rawPart = json['part'];
      return rawPart is Map && rawPart['type']?.toString() == 'reasoning';
    }
    if (json['type'] != null && json['type'].toString().isNotEmpty) {
      return false;
    }
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return false;
    }
    final delta = (choices.first as Map)['delta'];
    if (delta is! Map) return false;
    return delta['reasoning_content'] != null || delta['reasoning'] != null;
  }

  Future<void> _materializePendingMutation(
    List<ChatMessage> messages,
    GenerationCursor cursor,
  ) async {
    final pending = await RuntimeEventClient.instance.loadPendingCommand();
    if (pending == null || pending.generationId != cursor.generationId) return;
    final targetIndex = messages.indexWhere(
      (message) => message.eventId == pending.targetEventId,
    );
    if (targetIndex < 0) return;
    final target = messages[targetIndex];
    if (pending.kind == 'edit') {
      final existing = _findMessageByClientId(pending.userClientEventId);
      if (existing == null) {
        final replacement = _editedUserReplacement(
          target,
          pending.localContent ?? target.content,
          clientEventId: pending.userClientEventId,
          generationId: pending.generationId,
          epochId: pending.epochId,
        );
        final currentReply = _activeReply;
        final preserveCurrentReply =
            currentReply != null &&
            currentReply.generationId == pending.generationId;
        messages
          ..removeRange(targetIndex, messages.length)
          ..add(replacement);
        if (preserveCurrentReply && !messages.contains(currentReply)) {
          messages.add(currentReply);
        }
      }
    } else if (pending.kind == 'regenerate') {
      target
        ..generationId = pending.generationId
        ..epochId = pending.epochId;
      for (var index = messages.length - 1; index > targetIndex; index--) {
        final candidate = messages[index];
        if (candidate.role != 'assistant') continue;
        final isCurrentCommandReply =
            candidate.clientEventId == pending.assistantClientEventId ||
            candidate.generationId == pending.generationId;
        if (!isCurrentCommandReply) messages.removeAt(index);
      }
    }
    await _save(messages);
  }

  Future<void> _handleStreamTermux(
    Map<String, dynamic> json,
    String generationId,
  ) async {
    final payloadGenerationId =
        (json['generation_id']?.toString() ?? '').trim().isNotEmpty
        ? json['generation_id'].toString().trim()
        : generationId;
    if (payloadGenerationId != generationId) {
      throw const RuntimeException(
        'device_tool_identity_invalid',
        '手机工具 generation_id 与当前回复轮次不一致',
      );
    }
    final round = (json['round'] as num?)?.toInt() ?? 1;
    final calls = <Map<String, dynamic>>[
      for (final call in (json['calls'] as List<dynamic>? ?? const []))
        if (call is Map)
          call.map((key, value) => MapEntry(key.toString(), value)),
    ];
    _busy = true;
    _busyRound = round;
    _deviceRunning = true;
    _notify();
    final hasCanonicalSignal =
        (json['generation_id']?.toString() ?? '').trim().isNotEmpty ||
        calls.any(
          (call) =>
              (call['generation_id']?.toString() ?? '').trim().isNotEmpty ||
              (call['tool_call_id']?.toString() ?? '').trim().isNotEmpty,
        );
    if (hasCanonicalSignal &&
        (calls.isEmpty ||
            !calls.every(
              (call) =>
                  (call['tool_call_id']?.toString() ?? '').trim().isNotEmpty,
            ))) {
      throw const RuntimeException(
        'device_tool_identity_invalid',
        '手机工具 canonical identity 不完整',
      );
    }
    if (hasCanonicalSignal) {
      final reported = await DeviceCapabilityBridge.instance
          .executeStreamTermux(generationId: payloadGenerationId, calls: calls);
      if (!reported) {
        throw const RuntimeException(
          'device_tool_report_failed',
          '手机工具结果暂未回传成功',
        );
      }
    } else {
      final chatId = json['chat_id']?.toString() ?? '';
      final commands = <String>[
        for (final command in (json['commands'] as List<dynamic>? ?? const []))
          command.toString(),
      ];
      if (chatId.isEmpty) return;
      await DeviceCapabilityBridge.instance.executeLegacyStreamTermux(
        chatId: chatId,
        round: round,
        commands: commands,
      );
    }
    if (_activeReply?.generationId != generationId) return;
    _insertToolDoneMarker();
  }

  Future<void> _handleStreamNudge(
    Map<String, dynamic> json,
    String generationId,
  ) async {
    final payloadGenerationId =
        (json['generation_id']?.toString() ?? '').trim().isNotEmpty
        ? json['generation_id'].toString().trim()
        : generationId;
    if (payloadGenerationId != generationId) {
      throw const RuntimeException(
        'device_tool_identity_invalid',
        '手机工具 generation_id 与当前回复轮次不一致',
      );
    }
    final round = (json['round'] as num?)?.toInt() ?? 1;
    final calls = <Map<String, dynamic>>[
      for (final call in (json['calls'] as List<dynamic>? ?? const []))
        if (call is Map)
          call.map((key, value) => MapEntry(key.toString(), value)),
    ];
    _busy = true;
    _busyRound = round;
    _deviceRunning = true;
    _notify();
    final hasCanonicalSignal =
        (json['generation_id']?.toString() ?? '').trim().isNotEmpty ||
        calls.any(
          (call) =>
              (call['generation_id']?.toString() ?? '').trim().isNotEmpty ||
              (call['tool_call_id']?.toString() ?? '').trim().isNotEmpty,
        );
    if (hasCanonicalSignal &&
        (calls.isEmpty ||
            !calls.every(
              (call) =>
                  (call['tool_call_id']?.toString() ?? '').trim().isNotEmpty,
            ))) {
      throw const RuntimeException(
        'device_tool_identity_invalid',
        '手机工具 canonical identity 不完整',
      );
    }
    if (hasCanonicalSignal) {
      final reported = await DeviceCapabilityBridge.instance.executeStreamNudge(
        generationId: payloadGenerationId,
        calls: calls,
      );
      if (!reported) {
        throw const RuntimeException(
          'device_tool_report_failed',
          '手机工具结果暂未回传成功',
        );
      }
    } else {
      final chatId = json['chat_id']?.toString() ?? '';
      if (chatId.isEmpty) return;
      await DeviceCapabilityBridge.instance.executeLegacyStreamNudge(
        chatId: chatId,
        round: round,
        calls: calls,
      );
    }
    if (_activeReply?.generationId != generationId) return;
    _insertToolDoneMarker();
  }

  void _applyLegacyDelta(ChatMessage reply, Map<String, dynamic> json) {
    final usageJson = json['usage'];
    if (usageJson is Map<String, dynamic> && usageJson.isNotEmpty) {
      reply.usage = MessageUsage.fromJson(usageJson);
    }
    if (_partsMode) return;
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) return;
    final delta = (choices.first as Map)['delta'];
    if (delta is! Map) return;
    final content = delta['content'];
    if (content is String && content.isNotEmpty) {
      final clean = _shellStripper.process(content);
      if (clean.isNotEmpty) _appendVisibleText(reply, clean);
    }
    final reasoningRaw = delta['reasoning_content'] ?? delta['reasoning'];
    final reasoning = switch (reasoningRaw) {
      final String s => s,
      final Map m =>
        (m['text'] ?? m['content'] ?? m['summary'] ?? '').toString(),
      final List l =>
        l
            .map(
              (item) => item is Map
                  ? (item['text'] ?? item['content'] ?? '').toString()
                  : item.toString(),
            )
            .join(),
      _ => null,
    };
    if (reasoning != null && reasoning.isNotEmpty) {
      _appendReasoningPart(
        reply,
        reasoning,
        round: (json['round'] as num?)?.toInt() ?? 1,
        status: 'streaming',
      );
    }
  }

  void _applyMetadata(Map<String, dynamic> json, GenerationCursor cursor) {
    final userRawEventId = _jsonInt(json['user_raw_event_id']);
    final assistantRawEventId = _jsonInt(json['assistant_raw_event_id']);
    final userEventId = json['user_event_id']?.toString();
    final assistantEventId = json['assistant_event_id']?.toString();
    final epochId = json['epoch_id']?.toString();
    final user = _findMessageByClientId(cursor.userClientEventId);
    if (user != null) {
      user.rawEventId = userRawEventId ?? user.rawEventId;
      if (userEventId != null && userEventId.isNotEmpty) {
        user.eventId = userEventId;
      }
      if (epochId != null && epochId.isNotEmpty) user.epochId = epochId;
    }
    final reply = _findMessageByClientId(cursor.assistantClientEventId);
    if (reply != null) {
      reply.rawEventId = assistantRawEventId ?? reply.rawEventId;
      if (assistantEventId != null && assistantEventId.isNotEmpty) {
        reply.eventId = assistantEventId;
      }
      if (epochId != null && epochId.isNotEmpty) reply.epochId = epochId;
    }
  }

  Future<void> _finishByStatus(
    ChatMessage reply,
    GenerationTerminalStatus status, {
    bool stopped = false,
  }) async {
    final messages = await _ensureMessages();
    _markPartsDone(reply);
    if (!stopped &&
        status == GenerationTerminalStatus.completed &&
        !_replyHasVisibleOutput(reply)) {
      _replaceReplyWithNoResponse(messages, reply, '无回应');
    }
    if ((status == GenerationTerminalStatus.cancelled || stopped) &&
        !_replyHasVisibleOutput(reply)) {
      messages.remove(reply);
    }
    _sending = false;
    _commandStarting = false;
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _activeReply = null;
    if (_cancelRequestedGenerationId == reply.generationId) {
      _cancelRequestedGenerationId = null;
    }
    await RuntimeEventClient.instance.clearPendingCommand(
      generationId: reply.generationId,
    );
    await _commitImmediately(messages);
    if (status == GenerationTerminalStatus.completed &&
        reply.role == 'assistant') {
      unawaited(NewMessageNotifier.instance.maybeNotify(reply.content));
    }
  }

  Future<void> _settleReplayUnavailable() async {
    await _settleReplayFailure(
      '上次回复的运行记录已失效，无法继续恢复',
      code: 'replay_unavailable',
    );
  }

  Future<void> _settleReplayFailure(
    String message, {
    required String code,
  }) async {
    final messages = await _ensureMessages();
    final reply = _activeReply;
    final user = reply == null
        ? _findMessageByClientId(
            RuntimeEventClient.instance.cursor?.userClientEventId,
          )
        : _findPreviousUser(reply);
    final generationId =
        reply?.generationId ?? RuntimeEventClient.instance.cursor?.generationId;
    if (reply != null && !_replyHasVisibleOutput(reply)) {
      messages.remove(reply);
      if (user != null && user.role == 'user') {
        user
          ..sendFailed = true
          ..sendError = '$message（$code）';
      }
    } else if (reply != null) {
      reply.runtimeStatus = 'failed';
      _markLatestProcessSectionFailed(reply);
    } else if (user != null && user.role == 'user') {
      user
        ..sendFailed = true
        ..sendError = '$message（$code）';
    }
    _sending = false;
    _commandStarting = false;
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _activeReply = null;
    if (_cancelRequestedGenerationId == generationId) {
      _cancelRequestedGenerationId = null;
    }
    await RuntimeEventClient.instance.clearCursor(generationId: generationId);
    if (code == 'replay_unavailable') {
      await RuntimeEventClient.instance.clearPendingCommand(
        generationId: generationId,
      );
    }
    await _commitImmediately(messages);
  }

  Future<void> _failAttachedGeneration(
    ChatMessage reply,
    String message, {
    String code = 'generation_resume_failed',
  }) async {
    final messages = await _ensureMessages();
    final user = _findPreviousUser(reply);
    if (!_replyHasVisibleOutput(reply)) {
      messages.remove(reply);
      if (user != null) {
        user
          ..sendFailed = true
          ..sendError = '$message（$code）';
      }
    } else {
      reply.runtimeStatus = 'failed';
      _markLatestProcessSectionFailed(reply);
    }
    _sending = false;
    _commandStarting = false;
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _activeReply = null;
    if (_cancelRequestedGenerationId == reply.generationId) {
      _cancelRequestedGenerationId = null;
    }
    await RuntimeEventClient.instance.clearCursor(
      generationId: reply.generationId,
    );
    await _commitImmediately(messages);
  }

  Future<void> _failStartedMessage(
    ChatMessage sentMessage,
    ChatMessage reply,
    String message, {
    String code = 'chat_failed',
  }) async {
    final messages = await _ensureMessages();
    if (!_replyHasVisibleOutput(reply)) {
      messages.remove(reply);
      sentMessage
        ..sendFailed = true
        ..sendError = '$message（$code）';
    } else {
      reply.runtimeStatus = 'failed';
      _markLatestProcessSectionFailed(reply);
    }
    _sending = false;
    _commandStarting = false;
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
    _activeReply = null;
    final generationId = sentMessage.generationId ?? reply.generationId;
    if (_cancelRequestedGenerationId == generationId) {
      _cancelRequestedGenerationId = null;
    }
    await RuntimeEventClient.instance.clearCursor(generationId: generationId);
    await _commitImmediately(messages);
  }

  Future<void> _failActiveReply(String message, {String code = 'chat_failed'}) {
    final reply = _activeReply;
    if (reply == null) return Future<void>.value();
    return _failStartedMessage(
      _findPreviousUser(reply) ?? reply,
      reply,
      message,
      code: code,
    );
  }

  void _applyIncomingPart(ChatMessage reply, ChatMessagePart part) {
    switch (part.type) {
      case ChatMessagePartType.text:
        _appendVisibleText(
          reply,
          part.delta.isNotEmpty ? part.delta : part.text,
          round: max(part.round, 0),
        );
      case ChatMessagePartType.reasoning:
        _appendReasoningPart(
          reply,
          part.delta.isNotEmpty ? part.delta : part.text,
          round: part.round <= 0 ? 1 : part.round,
          status: part.status.isEmpty ? 'streaming' : part.status,
        );
      case ChatMessagePartType.tool:
        _upsertToolPart(reply, part);
      case ChatMessagePartType.image:
        _appendImagePart(reply, part.url);
    }
  }

  void _applyCanonicalReplySnapshot(
    ChatMessage reply,
    Map<String, dynamic> event,
  ) {
    final rawParts = event['parts'];
    final parts = <ChatMessagePart>[
      if (rawParts is List)
        for (final part in rawParts)
          if (part is Map)
            ChatMessagePart.fromJson(
              part.map((key, value) => MapEntry(key.toString(), value)),
            ),
    ];
    final content = (event['content'] ?? '').toString();
    final canonicalHasVisibleOutput =
        content.trim().isNotEmpty ||
        parts.any(
          (part) => switch (part.type) {
            ChatMessagePartType.text => part.text.trim().isNotEmpty,
            ChatMessagePartType.image => part.url.trim().isNotEmpty,
            ChatMessagePartType.tool =>
              part.status == 'done' ||
                  part.tools.any((tool) => tool.result.trim().isNotEmpty),
            ChatMessagePartType.reasoning => false,
          },
        );
    if (canonicalHasVisibleOutput) {
      reply
        ..content = content
        ..parts = parts;
      _partsMode = parts.isNotEmpty;
    }
    reply
      ..eventId = event['event_id']?.toString() ?? reply.eventId
      ..epochId = event['epoch_id']?.toString() ?? reply.epochId
      ..generationId = event['generation_id']?.toString() ?? reply.generationId
      ..rawEventId = _jsonInt(event['raw_event_id']) ?? reply.rawEventId;
  }

  void _markBusy(ChatMessage reply, int round) {
    if (_busy && _busyRound != round) _insertToolDoneMarker();
    _busy = true;
    _busyRound = round;
    _upsertToolPart(
      reply,
      ChatMessagePart(
        type: ChatMessagePartType.tool,
        round: round,
        status: 'running',
      ),
    );
  }

  void _insertToolDoneMarker() {
    final reply = _activeReply;
    final round = _busyRound;
    if (reply != null && round > 0) {
      _upsertToolPart(
        reply,
        ChatMessagePart(
          type: ChatMessagePartType.tool,
          round: round,
          status: 'done',
        ),
      );
    }
    _busy = false;
    _busyRound = 0;
    _deviceRunning = false;
  }

  void _appendVisibleText(ChatMessage reply, String text, {int round = 0}) {
    if (text.isEmpty) return;
    reply.content += text;
    final parts = List<ChatMessagePart>.from(reply.parts);
    if (parts.isNotEmpty &&
        parts.last.type == ChatMessagePartType.text &&
        parts.last.round == round) {
      parts.last.text += text;
    } else {
      parts.add(
        ChatMessagePart(
          type: ChatMessagePartType.text,
          text: text,
          round: round,
        ),
      );
    }
    reply.parts = parts;
  }

  void _appendReasoningPart(
    ChatMessage reply,
    String rawText, {
    required int round,
    required String status,
  }) {
    final clean = rawText;
    if (clean.isEmpty && status != 'done') return;
    final idx = max(round, 1) - 1;
    final mutable = List<String>.from(reply.reasonings);
    while (mutable.length < idx) {
      mutable.add('');
    }
    if (mutable.length == idx) {
      mutable.add(clean);
    } else if (clean.isNotEmpty) {
      mutable[idx] = mutable[idx] + clean;
    }
    reply.reasonings = mutable;
    if (clean.isNotEmpty) reply.reasoning += clean;
    final parts = List<ChatMessagePart>.from(reply.parts);
    final partIndex = parts.lastIndexWhere(
      (part) =>
          part.type == ChatMessagePartType.reasoning && part.round == round,
    );
    if (partIndex >= 0) {
      parts[partIndex].text += clean;
      parts[partIndex].status = status;
    } else {
      parts.add(
        ChatMessagePart(
          type: ChatMessagePartType.reasoning,
          text: clean,
          round: round,
          status: status,
        ),
      );
    }
    reply.parts = parts;
  }

  void _upsertToolPart(ChatMessage reply, ChatMessagePart incoming) {
    final round = incoming.round <= 0 ? _busyRound : incoming.round;
    final parts = List<ChatMessagePart>.from(reply.parts);
    final idx = parts.lastIndexWhere(
      (part) => part.type == ChatMessagePartType.tool && part.round == round,
    );
    final status = incoming.status.isEmpty ? 'running' : incoming.status;
    if (idx >= 0) {
      parts[idx].status = status;
      if (incoming.tools.isNotEmpty) parts[idx].tools = incoming.tools;
    } else {
      parts.add(
        ChatMessagePart(
          type: ChatMessagePartType.tool,
          round: round,
          status: status,
          tools: incoming.tools,
        ),
      );
    }
    reply.parts = parts;
    if (status == 'done' &&
        round > 0 &&
        !reply.toolDoneRounds.contains(round)) {
      reply.toolDoneRounds = List<int>.from(reply.toolDoneRounds)..add(round);
    }
  }

  void _appendImagePart(ChatMessage reply, String url) {
    if (url.isEmpty) return;
    reply.parts = List<ChatMessagePart>.from(reply.parts)
      ..add(ChatMessagePart(type: ChatMessagePartType.image, url: url));
    if (reply.imageUrl == null || reply.imageUrl!.isEmpty) {
      reply.imageUrl = url;
    } else if (!reply.imageUrls.contains(url)) {
      reply.imageUrls = List<String>.from(reply.imageUrls)..add(url);
    }
  }

  void _markPartsDone(ChatMessage reply) {
    final parts = List<ChatMessagePart>.from(reply.parts);
    for (final part in parts) {
      if ((part.type == ChatMessagePartType.reasoning ||
              part.type == ChatMessagePartType.tool) &&
          (part.status == 'streaming' || part.status == 'running')) {
        part.status = 'done';
      }
    }
    reply.parts = parts;
  }

  void _markLatestProcessSectionFailed(ChatMessage reply) {
    final parts = List<ChatMessagePart>.from(reply.parts);
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].type == ChatMessagePartType.reasoning ||
          parts[i].type == ChatMessagePartType.tool) {
        parts[i].status = 'failed';
      } else {
        break;
      }
    }
    reply.parts = parts;
  }

  bool _replyHasVisibleOutput(ChatMessage reply) {
    return reply.content.trim().isNotEmpty ||
        reply.parts.any(
          (part) => switch (part.type) {
            ChatMessagePartType.text => part.text.trim().isNotEmpty,
            ChatMessagePartType.image => part.url.trim().isNotEmpty,
            ChatMessagePartType.tool =>
              part.status == 'done' ||
                  part.tools.any((tool) => tool.result.trim().isNotEmpty),
            ChatMessagePartType.reasoning => false,
          },
        ) ||
        (reply.imageUrl != null && reply.imageUrl!.isNotEmpty) ||
        reply.imageUrls.isNotEmpty ||
        reply.toolDoneRounds.isNotEmpty;
  }

  ChatMessage _replaceReplyWithNoResponse(
    List<ChatMessage> messages,
    ChatMessage reply,
    String content,
  ) {
    final idx = messages.indexOf(reply);
    final card = ChatMessage(
      role: 'activity',
      content: content.trim().isEmpty ? '无回应' : content.trim(),
      time: reply.time,
      eventId: reply.eventId,
      clientEventId: reply.clientEventId,
      generationId: reply.generationId,
      epochId: reply.epochId,
      kind: 'no_response',
      runtimeSeq: reply.runtimeSeq,
      runtimeStatus: reply.runtimeStatus,
    );
    if (idx >= 0) {
      messages[idx] = card;
    } else {
      messages.add(card);
    }
    return card;
  }

  ChatMessage _editedUserReplacement(
    ChatMessage source,
    String text, {
    required String clientEventId,
    required String generationId,
    required String epochId,
  }) {
    return ChatMessage(
      role: 'user',
      content: text,
      clientEventId: clientEventId,
      generationId: generationId,
      epochId: epochId,
      kind: 'user',
      imageUrl: source.imageUrl,
      ocrText: source.ocrText,
      imageUrls: List<String>.from(source.imageUrls),
      imageOcrTexts: List<String>.from(source.imageOcrTexts),
      fileUrl: source.fileUrl,
      fileName: source.fileName,
      fileSize: source.fileSize,
      fileType: source.fileType,
      fileExtractedText: source.fileExtractedText,
      parts: List<ChatMessagePart>.from(source.parts),
    );
  }

  String _responseString(Map<String, dynamic> response, String key) =>
      (response[key] ?? '').toString().trim();

  void _reconcileCanonicalBranch(
    List<ChatMessage> messages,
    List<dynamic> activeBranch,
    ChatMessage preferredUser,
  ) {
    final original = List<ChatMessage>.of(messages);
    final existingByEventId = <String, ChatMessage>{
      for (final message in original)
        if ((message.eventId ?? '').isNotEmpty) message.eventId!: message,
    };
    final claimed = <ChatMessage>{};
    var legacySearchFrom = 0;
    final next = <ChatMessage>[];
    for (final raw in activeBranch) {
      if (raw is! Map) continue;
      final row = raw.map((key, value) => MapEntry(key.toString(), value));
      final eventId = (row['event_id'] ?? '').toString().trim();
      if (eventId.isEmpty) continue;
      ChatMessage? message;
      if (preferredUser.eventId == eventId) {
        message = preferredUser;
      } else {
        message = existingByEventId[eventId];
      }
      message ??= _claimLegacyLocalMessage(
        original,
        claimed,
        row,
        searchFrom: legacySearchFrom,
      );
      if (message != null) {
        final position = original.indexOf(message);
        if (position >= legacySearchFrom) legacySearchFrom = position + 1;
        claimed.add(message);
      }
      if (message == null) {
        message = _messageFromCanonicalRow(row, eventId);
      } else {
        _applyCanonicalIdentity(message, row, eventId);
      }
      next.add(message);
    }
    if (next.isNotEmpty) {
      messages
        ..clear()
        ..addAll(next);
    }
  }

  ChatMessage? _claimLegacyLocalMessage(
    List<ChatMessage> original,
    Set<ChatMessage> claimed,
    Map<String, dynamic> row, {
    required int searchFrom,
  }) {
    final rowClient = (row['client_event_id'] ?? '').toString().trim();
    final rowRaw = _jsonInt(row['raw_event_id']);
    for (var i = searchFrom; i < original.length; i++) {
      final local = original[i];
      if (claimed.contains(local) || (local.eventId ?? '').isNotEmpty) continue;
      if (local.role != (row['role'] ?? '').toString()) continue;
      final localClient = (local.clientEventId ?? '').trim();
      if (rowClient.isNotEmpty && localClient.isNotEmpty) {
        if (rowClient == localClient) return local;
        continue;
      }
      if (rowRaw != null && local.rawEventId != null) {
        if (rowRaw == local.rawEventId) return local;
        continue;
      }
      final canonicalContent = (row['content'] ?? '').toString();
      final localCanonicalContent = local.role == 'user'
          ? ChatApi.runtimeMutationContent(local)
          : local.content;
      if (localCanonicalContent == canonicalContent) return local;
    }
    return null;
  }

  ChatMessage _messageFromCanonicalRow(
    Map<String, dynamic> row,
    String eventId,
  ) {
    final parts = <ChatMessagePart>[];
    final rawParts = row['parts'];
    if (rawParts is List) {
      for (final part in rawParts) {
        if (part is Map) {
          parts.add(
            ChatMessagePart.fromJson(
              part.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
    }
    return ChatMessage(
      role: (row['role'] ?? 'assistant').toString(),
      content: (row['content'] ?? '').toString(),
      eventId: eventId,
      clientEventId: row['client_event_id']?.toString(),
      generationId: row['generation_id']?.toString(),
      epochId: row['epoch_id']?.toString(),
      kind: row['kind']?.toString(),
      rawEventId: _jsonInt(row['raw_event_id']),
      parts: parts,
    );
  }

  void _applyCanonicalIdentity(
    ChatMessage message,
    Map<String, dynamic> row,
    String eventId,
  ) {
    message.eventId = eventId;
    final rowEpoch = row['epoch_id']?.toString();
    if (rowEpoch != null && rowEpoch.isNotEmpty) message.epochId = rowEpoch;
    final rowGeneration = row['generation_id']?.toString();
    if (rowGeneration != null && rowGeneration.isNotEmpty) {
      message.generationId = rowGeneration;
    }
    final rowClient = row['client_event_id']?.toString();
    if ((message.clientEventId ?? '').isEmpty &&
        rowClient != null &&
        rowClient.isNotEmpty) {
      message.clientEventId = rowClient;
    }
    message.rawEventId = _jsonInt(row['raw_event_id']) ?? message.rawEventId;
  }

  ChatMessage? _findPreviousUser(ChatMessage reply) {
    final messages = _messages;
    if (messages == null) return null;
    final idx = messages.indexOf(reply);
    if (idx < 0) return null;
    for (var i = idx - 1; i >= 0; i--) {
      if (messages[i].role == 'user') return messages[i];
    }
    return null;
  }

  ChatMessage? _findMessageByClientId(String? clientEventId) {
    if (clientEventId == null || clientEventId.isEmpty) return null;
    final messages = _messages;
    if (messages == null) return null;
    for (final message in messages) {
      if (message.clientEventId == clientEventId) return message;
    }
    return null;
  }

  Future<List<ChatMessage>> _ensureMessages() async {
    final existing = _messages;
    if (existing != null) return existing;
    final pending = _messagesLoading;
    if (pending != null) return pending;

    late final Future<List<ChatMessage>> loading;
    loading = () async {
      final loaded = ChatStore.cache ?? await ChatStore.warmUp();
      final current = _messages;
      if (current != null) return current;
      _messages = loaded;
      ChatStore.cache = loaded;
      return loaded;
    }();
    _messagesLoading = loading;
    try {
      return await loading;
    } finally {
      if (identical(_messagesLoading, loading)) _messagesLoading = null;
    }
  }

  Future<void> _save(List<ChatMessage> messages) async {
    ChatStore.cache = messages;
    await ChatStore.save(messages);
  }

  void _notify() {
    notifyListeners();
  }

  // ---- 流式节流：UI 通知与 checkpoint 落盘各自合帧，职责不共用 timer ----

  void _scheduleStreamingUiNotify({Duration window = streamUiCoalesceWindow}) {
    final active = _streamUiTimer;
    final activeWindow = _streamUiWindow;
    if (active != null && activeWindow != null) {
      // A normal text delta needs the faster 16ms path even if an 80ms
      // reasoning batch is already pending. Never let reasoning batching delay
      // visible正文.
      if (activeWindow <= window) return;
      active.cancel();
    }
    _streamUiWindow = window;
    _streamUiTimer = Timer(window, () {
      _streamUiTimer = null;
      _streamUiWindow = null;
      notifyListeners();
    });
  }

  /// 流式过程中至多每 [streamCheckpointInterval] 落盘一次。定时器只在空闲时
  /// 重新挂载，写盘捕获的是触发那一刻的 canonical 列表快照，因此后续增量
  /// 要么落在这次 checkpoint 里，要么落在下一次。
  void _scheduleStreamingCheckpoint(
    List<ChatMessage> messages,
    String generationId,
  ) {
    _pendingCheckpointMessages = messages;
    _pendingCheckpointGenerationId = generationId;
    _streamCheckpointTimer ??= Timer(
      streamCheckpointInterval,
      _drainStreamingCheckpoint,
    );
  }

  void _drainStreamingCheckpoint() {
    _streamCheckpointTimer = null;
    final pending = _pendingCheckpointMessages;
    final pendingGenerationId = _pendingCheckpointGenerationId;
    _pendingCheckpointMessages = null;
    _pendingCheckpointGenerationId = null;
    if (pending == null) return;
    final activeGenerationId = (_activeReply?.generationId ?? '').trim();
    if (pendingGenerationId != null &&
        activeGenerationId.isNotEmpty &&
        pendingGenerationId != activeGenerationId) {
      // 旧 generation 的迟到 checkpoint：它的内容已由该 generation 的终态
      // flush 落盘，不为新 generation 重复写盘。
      return;
    }
    final write = _save(pending);
    _streamCheckpointWrite = write;
    unawaited(
      write.whenComplete(() {
        if (identical(_streamCheckpointWrite, write)) {
          _streamCheckpointWrite = null;
        }
      }),
    );
  }

  /// 终态 / 关键状态边界：取消合帧，立即把最后一批内容落盘并通知 UI。
  Future<void> _commitImmediately(List<ChatMessage> messages) async {
    _cancelStreamingTimers();
    await _save(messages);
    _notify();
  }

  /// 把已经收到但尚未 checkpoint 的流式内容立即落盘（切后台 / 页面 dispose）。
  /// 这里不发 UI 通知：这些调用点都不是 UI 需要刷新的事件。
  Future<void> flushPendingStreamingWork() {
    final active = _streamFlushFuture;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _flushPendingStreamingWork().whenComplete(() {
      if (identical(_streamFlushFuture, operation)) _streamFlushFuture = null;
    });
    _streamFlushFuture = operation;
    return operation;
  }

  Future<void> _flushPendingStreamingWork() async {
    _streamUiTimer?.cancel();
    _streamUiTimer = null;
    _streamUiWindow = null;
    final pending = _pendingCheckpointMessages;
    _streamCheckpointTimer?.cancel();
    _streamCheckpointTimer = null;
    _pendingCheckpointMessages = null;
    _pendingCheckpointGenerationId = null;
    final inFlight = _streamCheckpointWrite;
    if (inFlight != null) await inFlight;
    if (pending != null) await _save(pending);
  }

  void _cancelStreamingTimers() {
    _streamUiTimer?.cancel();
    _streamUiTimer = null;
    _streamUiWindow = null;
    _streamCheckpointTimer?.cancel();
    _streamCheckpointTimer = null;
    _pendingCheckpointMessages = null;
    _pendingCheckpointGenerationId = null;
  }

  int? _jsonInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
