import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/api_client.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  List<Map<String, dynamic>> _tools = const [];
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
      final response = await widget.api.getJson('/mcp/tools');
      final values = response['tools'];
      if (!mounted) return;
      setState(() {
        _tools = values is List
            ? values.whereType<Map<String, dynamic>>().toList()
            : const [];
      });
    } catch (caught) {
      if (mounted) setState(() => _error = caught.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _invoke(Map<String, dynamic> tool) async {
    final arguments = TextEditingController(text: '{}');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tool['name']?.toString() ?? 'Invoke tool'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: arguments,
            minLines: 5,
            maxLines: 14,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'JSON arguments'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, arguments.text),
            child: const Text('Invoke'),
          ),
        ],
      ),
    );
    arguments.dispose();
    if (result == null) return;
    try {
      final decoded = jsonDecode(result);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Arguments must be a JSON object.');
      }
      final response = await widget.api.postJson('/mcp/test', {
        'server': tool['server']?.toString() ?? '',
        'tool': tool['name']?.toString() ?? '',
        'arguments': decoded,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Tool result'),
          content: SingleChildScrollView(
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(response['result']),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (caught) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(caught.toString())));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Tools'),
      actions: [
        IconButton(
          tooltip: 'Refresh tools',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: _body(),
  );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_tools.isEmpty) {
      return const Center(child: Text('No enabled MCP tools.'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: _tools.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final tool = _tools[index];
          return Card(
            child: ListTile(
              title: Text(tool['name']?.toString() ?? 'Unnamed tool'),
              subtitle: Text(
                '${tool['server'] ?? 'Unknown server'}\n${tool['description'] ?? ''}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.play_arrow),
              onTap: () => _invoke(tool),
            ),
          );
        },
      ),
    );
  }
}
