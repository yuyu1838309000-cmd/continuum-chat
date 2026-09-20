import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../services/server_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.config,
    required this.onSaveConfig,
  });

  final ApiClient api;
  final ServerConfig config;
  final Future<void> Function(ServerConfig) onSaveConfig;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _scheme = TextEditingController(text: widget.config.scheme);
  late final _host = TextEditingController(text: widget.config.host);
  late final _runtimePort = TextEditingController(
    text: widget.config.runtimePort.toString(),
  );
  late final _memoryPort = TextEditingController(
    text: widget.config.memoryPort.toString(),
  );
  late final _token = TextEditingController(text: widget.config.token);
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _providerKey = TextEditingController();
  final _endpoint = TextEditingController();
  final _mcp = TextEditingController();
  bool _loadingRemote = false;
  bool _providerKeyConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadRemote();
  }

  Future<void> _saveConnection() async {
    final config = ServerConfig(
      scheme: _scheme.text.trim().toLowerCase(),
      host: _host.text.trim(),
      runtimePort: int.tryParse(_runtimePort.text) ?? 0,
      memoryPort: int.tryParse(_memoryPort.text) ?? 0,
      token: _token.text.trim(),
    );
    if (config.validate() case final error?) {
      _show(error);
      return;
    }
    try {
      await widget.onSaveConfig(config);
      _show('Connection settings saved.');
    } catch (caught) {
      _show(caught.toString());
    }
  }

  Future<void> _loadRemote() async {
    setState(() => _loadingRemote = true);
    try {
      final results = await Future.wait([
        widget.api.getJson('/config/provider'),
        widget.api.getJson('/config/mcp'),
      ]);
      if (!mounted) return;
      final provider = results[0];
      _baseUrl.text = provider['base_url']?.toString() ?? '';
      _model.text = provider['model']?.toString() ?? '';
      _endpoint.text = provider['endpoint']?.toString() ?? '/chat/completions';
      _providerKey.clear();
      _providerKeyConfigured = provider['api_key'] == 'configured';
      _mcp.text = const JsonEncoder.withIndent('  ').convert(results[1]);
      setState(() {});
    } catch (caught) {
      _show(caught.toString());
    } finally {
      if (mounted) setState(() => _loadingRemote = false);
    }
  }

  Future<void> _saveProvider() async {
    if (_baseUrl.text.trim().isEmpty || _model.text.trim().isEmpty) {
      _show('Base URL and model are required.');
      return;
    }
    try {
      await widget.api.putJson('/config/provider', {
        'base_url': _baseUrl.text.trim(),
        'model': _model.text.trim(),
        'api_key': _providerKey.text,
        'endpoint': _endpoint.text.trim(),
      });
      _show('Provider configuration saved.');
      await _loadRemote();
    } catch (caught) {
      _show(caught.toString());
    }
  }

  Future<void> _saveMcp() async {
    try {
      final decoded = jsonDecode(_mcp.text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('MCP config must be a JSON object.');
      }
      await widget.api.putJson('/config/mcp', decoded);
      _show('MCP configuration saved.');
      await _loadRemote();
    } catch (caught) {
      _show(caught.toString());
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    for (final controller in [
      _scheme,
      _host,
      _runtimePort,
      _memoryPort,
      _token,
      _baseUrl,
      _model,
      _providerKey,
      _endpoint,
      _mcp,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Settings'),
      actions: [
        IconButton(
          tooltip: 'Reload server config',
          onPressed: _loadingRemote ? null : _loadRemote,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _Section(
          title: 'Connection',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _field(_scheme, 'Scheme')),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _field(_host, 'Host')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _runtimePort,
                      'Runtime port',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _memoryPort,
                      'Memory port',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'API token'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saveConnection,
                  child: const Text('Save connection'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Provider',
          child: Column(
            children: [
              _field(_baseUrl, 'Base URL'),
              const SizedBox(height: 12),
              _field(_model, 'Model'),
              const SizedBox(height: 12),
              _field(_endpoint, 'Endpoint'),
              const SizedBox(height: 12),
              TextField(
                controller: _providerKey,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'API key',
                  helperText: _providerKeyConfigured
                      ? 'A key is configured. Enter a value to replace it; saving blank clears it.'
                      : 'No key is configured.',
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _loadingRemote ? null : _saveProvider,
                  child: const Text('Save provider'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'MCP JSON',
          child: Column(
            children: [
              TextField(
                controller: _mcp,
                minLines: 10,
                maxLines: 24,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: '{\n  "servers": {}\n}',
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _loadingRemote ? null : _saveMcp,
                  child: const Text('Save MCP config'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
  }) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    autocorrect: false,
    decoration: InputDecoration(labelText: label),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}
