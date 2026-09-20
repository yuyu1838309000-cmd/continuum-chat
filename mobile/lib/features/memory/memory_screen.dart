import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import 'memory_card.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _search = TextEditingController();
  List<MemoryCard> _cards = const [];
  bool _loading = true;
  String? _error;
  bool _isRecall = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => _fetch('/cards');

  Future<void> _recall() async {
    final query = _search.text.trim();
    if (query.isEmpty) return _load();
    await _fetch('/recall', query: {'q': query, 'limit': 30}, recall: true);
  }

  Future<void> _fetch(
    String path, {
    Map<String, dynamic>? query,
    bool recall = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.getJson(
        path,
        query: query,
        memory: true,
      );
      final values = response['cards'];
      if (!mounted) return;
      setState(() {
        _cards = values is List
            ? values
                  .whereType<Map<String, dynamic>>()
                  .map(MemoryCard.fromJson)
                  .toList()
            : const [];
        _isRecall = recall;
      });
    } catch (caught) {
      if (mounted) setState(() => _error = caught.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([MemoryCard? card]) async {
    final draft = await showDialog<_CardDraft>(
      context: context,
      builder: (context) => _CardDialog(card: card),
    );
    if (draft == null) return;
    try {
      final body = {
        'title': draft.title,
        'content': draft.content,
        'tags': draft.tags,
      };
      if (card == null) {
        await widget.api.postJson('/cards', body, memory: true);
      } else {
        await widget.api.putJson('/cards/${card.id}', body, memory: true);
      }
      await _load();
    } catch (caught) {
      _showError(caught);
    }
  }

  Future<void> _delete(MemoryCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete memory card?'),
        content: Text(card.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteJson('/cards/${card.id}', memory: true);
      await _load();
    } catch (caught) {
      _showError(caught);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Memory'),
      actions: [
        IconButton(
          tooltip: 'Add memory card',
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SearchBar(
            controller: _search,
            hintText: 'Recall memory cards',
            onSubmitted: (_) => _recall(),
            leading: const Icon(Icons.search),
            trailing: [
              if (_isRecall)
                IconButton(
                  tooltip: 'Clear recall',
                  onPressed: () {
                    _search.clear();
                    _load();
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return Center(
        child: FilledButton.tonal(
          onPressed: _load,
          child: Text('Retry: $error'),
        ),
      );
    }
    if (_cards.isEmpty) {
      return Center(
        child: Text(_isRecall ? 'No matching cards.' : 'No memory cards yet.'),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        itemCount: _cards.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final card = _cards[index];
          return Card(
            child: ListTile(
              title: Text(card.title),
              subtitle: Text(
                [
                  card.content,
                  if (card.tags.isNotEmpty) card.tags.join(' · '),
                ].join('\n'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _edit(card),
              trailing: IconButton(
                tooltip: 'Delete',
                onPressed: () => _delete(card),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CardDraft {
  const _CardDraft(this.title, this.content, this.tags);

  final String title;
  final String content;
  final List<String> tags;
}

class _CardDialog extends StatefulWidget {
  const _CardDialog({this.card});

  final MemoryCard? card;

  @override
  State<_CardDialog> createState() => _CardDialogState();
}

class _CardDialogState extends State<_CardDialog> {
  late final _title = TextEditingController(text: widget.card?.title);
  late final _content = TextEditingController(text: widget.card?.content);
  late final _tags = TextEditingController(text: widget.card?.tags.join(', '));

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.card == null ? 'New memory card' : 'Edit memory card'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'Content'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags (comma separated)',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final title = _title.text.trim();
          final content = _content.text.trim();
          if (title.isEmpty || content.isEmpty) return;
          Navigator.pop(
            context,
            _CardDraft(
              title,
              content,
              _tags.text
                  .split(',')
                  .map((tag) => tag.trim())
                  .where((tag) => tag.isNotEmpty)
                  .toList(),
            ),
          );
        },
        child: const Text('Save'),
      ),
    ],
  );
}
