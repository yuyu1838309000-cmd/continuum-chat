import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../services/api_client.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ChatMessage> _messages = const [];
  List<Map<String, dynamic>> _days = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.getJson(
          '/runtime/history/messages',
          query: const {'conversation_id': 'default', 'limit': 1000},
        ),
        widget.api.getJson('/runtime/history/calendar'),
      ]);
      if (!mounted) return;
      setState(() {
        _messages = switch (results[0]['messages']) {
          final List values =>
            values
                .whereType<Map<String, dynamic>>()
                .map(ChatMessage.fromJson)
                .toList(),
          _ => const [],
        };
        _days = switch (results[1]['days']) {
          final List values =>
            values.whereType<Map<String, dynamic>>().toList(),
          _ => const [],
        };
      });
    } catch (caught) {
      if (mounted) setState(() => _error = caught.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('History'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: _body(),
  );

  Widget _body() {
    if (_loading && _messages.isEmpty && _days.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final error?) {
      return _ErrorState(message: error, onRetry: _load);
    }
    if (_messages.isEmpty && _days.isEmpty) {
      return const Center(child: Text('No history yet.'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('Daily usage', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_days.isEmpty)
            const Text('No provider usage recorded.')
          else
            Card(
              child: Column(
                children: [
                  for (final day in _days.reversed)
                    ListTile(
                      title: Text(day['day']?.toString() ?? 'Unknown day'),
                      subtitle: Text(
                        '${day['message_count'] ?? 0} messages · '
                        '${day['provider_usage_count'] ?? 0} provider calls',
                      ),
                      trailing: Text(
                        '${day['input_tokens'] ?? 0} in\n${day['output_tokens'] ?? 0} out',
                        textAlign: TextAlign.end,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text('Messages', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final message in _messages.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  title: Text(message.isUser ? 'You' : 'Assistant'),
                  subtitle: Text(
                    message.content.isEmpty
                        ? '(empty response)'
                        : message.content,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: message.createdAt == null
                      ? null
                      : Text(
                          message.createdAt!.toLocal().toString().substring(
                            0,
                            16,
                          ),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
