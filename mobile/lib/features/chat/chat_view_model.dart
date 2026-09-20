import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/chat_message.dart';
import '../../services/api_client.dart';

class ChatViewModel extends ChangeNotifier {
  ChatViewModel(this._api);

  final ApiClient _api;
  final List<ChatMessage> _messages = [];
  StreamSubscription<SseEvent>? _subscription;
  bool isLoading = true;
  bool isSending = false;
  bool _disposed = false;
  String? error;
  String? _lastMessage;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  Future<void> load() async {
    isLoading = true;
    error = null;
    _notify();
    try {
      final response = await _api.getJson(
        '/runtime/history/messages',
        query: const {'conversation_id': 'default', 'limit': 200},
      );
      final raw = response['messages'];
      _messages
        ..clear()
        ..addAll(
          raw is List
              ? raw.whereType<Map<String, dynamic>>().map(ChatMessage.fromJson)
              : const <ChatMessage>[],
        );
    } catch (caught) {
      error = caught.toString();
    } finally {
      isLoading = false;
      _notify();
    }
  }

  Future<void> send(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || isLoading || isSending) return;
    _lastMessage = message;
    error = null;
    isSending = true;
    final now = DateTime.now();
    _messages.add(
      ChatMessage(
        id: 'local-user-${now.microsecondsSinceEpoch}',
        role: 'user',
        content: message,
        createdAt: now,
      ),
    );
    _messages.add(
      ChatMessage(
        id: 'stream-${now.microsecondsSinceEpoch}',
        role: 'assistant',
        content: '',
        createdAt: now,
        isStreaming: true,
      ),
    );
    _notify();

    await _subscription?.cancel();
    final completer = Completer<void>();
    _subscription = _api
        .chat(message)
        .listen(
          (event) {
            final last = _messages.last;
            switch (event.type) {
              case 'text':
                _messages[_messages.length - 1] = last.copyWith(
                  content: last.content + (event.data?.toString() ?? ''),
                );
              case 'reasoning':
                _messages[_messages.length - 1] = last.copyWith(
                  reasoning: last.reasoning + (event.data?.toString() ?? ''),
                );
              case 'done':
                final raw = event.payload['message'];
                if (raw is Map<String, dynamic>) {
                  _messages[_messages.length - 1] = ChatMessage.fromJson(raw);
                }
            }
            _notify();
          },
          onError: (Object caught) async {
            final sendError = caught.toString();
            isSending = false;
            _messages.removeWhere(
              (message) =>
                  message.id.startsWith('local-user-') ||
                  message.id.startsWith('stream-'),
            );
            await load();
            error = sendError;
            _notify();
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () async {
            isSending = false;
            await load();
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
    await completer.future;
  }

  Future<void> retry() => _lastMessage == null ? load() : send(_lastMessage!);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
