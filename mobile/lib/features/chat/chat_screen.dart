import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../services/api_client.dart';
import 'chat_view_model.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final ChatViewModel _model = ChatViewModel(widget.api)
    ..addListener(_changed)
    ..load();

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await _model.send(text);
  }

  @override
  void dispose() {
    _model
      ..removeListener(_changed)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Continuum Chat'),
          Text('Local AI assistant', style: TextStyle(fontSize: 12)),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh history',
          onPressed: _model.isLoading || _model.isSending ? null : _model.load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          if (_model.error case final error?)
            MaterialBanner(
              content: Text(error),
              actions: [
                TextButton(onPressed: _model.retry, child: const Text('Retry')),
              ],
            ),
          Expanded(child: _messageList()),
          _Composer(
            controller: _input,
            enabled: !_model.isLoading && !_model.isSending,
            onSend: _send,
          ),
        ],
      ),
    ),
  );

  Widget _messageList() {
    if (_model.isLoading && _model.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_model.messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Start a conversation with the assistant.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: _model.messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) =>
          _MessageBubble(message: _model.messages[index]),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: message.isUser
                ? colors.primaryContainer
                : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.isUser ? 'You' : 'Assistant',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (message.reasoning.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text('Reasoning'),
                    dense: true,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(message.reasoning),
                      ),
                    ],
                  ),
                if (message.content.isNotEmpty) Text(message.content),
                if (message.isStreaming && message.content.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: 'Message the assistant',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: enabled ? onSend : null,
          icon: enabled
              ? const Icon(Icons.arrow_upward)
              : const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      ],
    ),
  );
}
