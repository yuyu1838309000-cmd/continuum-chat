import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/media_config_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

class SttConfigPage extends StatefulWidget {
  const SttConfigPage({super.key, this.mediaConfigApi});

  final MediaConfigApi? mediaConfigApi;

  @override
  State<SttConfigPage> createState() => _SttConfigPageState();
}

class _SttConfigPageState extends State<SttConfigPage> {
  static const String _enabledKey = 'stt_enabled';

  late final MediaConfigApi _api;
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  late final TextEditingController _modelController;
  bool _enabled = true;
  bool _keyConfigured = false;
  bool _showKey = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _api = widget.mediaConfigApi ?? MediaConfigApi();
    _urlController = TextEditingController();
    _keyController = TextEditingController();
    _modelController = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _enabled = prefs.getBool(_enabledKey) ?? true);
    final snapshot = await _api.load(onCache: _applySnapshot);
    _applySnapshot(snapshot);
    if (mounted) setState(() => _loading = false);
  }

  void _applySnapshot(MediaConfigSnapshot snapshot) {
    if (!mounted) return;
    final config = snapshot.stt;
    setState(() {
      _urlController.text = config.apiUrl;
      _modelController.text = config.model;
      _keyController.clear();
      _keyConfigured = config.keyConfigured;
    });
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _enabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  Future<void> _save() async {
    if (_urlController.text.trim().isEmpty ||
        _modelController.text.trim().isEmpty) {
      _showMessage('请填写服务地址和模型');
      return;
    }
    setState(() => _saving = true);
    try {
      final newKey = _keyController.text.trim();
      final snapshot = await _api.save(
        MediaFeature.stt,
        apiUrl: _urlController.text,
        model: _modelController.text,
        apiKey: newKey,
        updateApiKey: newKey.isNotEmpty,
      );
      _applySnapshot(snapshot);
      _showMessage('语音转文字配置已保存');
    } on Exception catch (error) {
      _showMessage(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearKey() async {
    if (!_keyConfigured || _saving) return;
    setState(() => _saving = true);
    try {
      final snapshot = await _api.save(
        MediaFeature.stt,
        apiKey: '',
        updateApiKey: true,
      );
      _applySnapshot(snapshot);
      _showMessage('已清除服务器 API Key');
    } on Exception catch (error) {
      _showMessage(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('语音转文字')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          SettingCard(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(
                LucideIcons.mic,
                size: 24,
                color: theme.colorScheme.primary,
              ),
              title: const Text('语音转文字'),
              value: _enabled,
              onChanged: _setEnabled,
            ),
          ),
          const AppSectionLabel('连接', compact: true),
          SettingCard(
            child: Column(
              children: [
                TextField(
                  key: const Key('stt-api-url'),
                  controller: _urlController,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    prefixIcon: Icon(LucideIcons.globe, size: 20),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: const Key('stt-api-key'),
                  controller: _keyController,
                  obscureText: !_showKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: _keyConfigured ? '已在服务器保存，留空保持不变' : '尚未配置',
                    prefixIcon: const Icon(LucideIcons.key, size: 20),
                    suffixIcon: IconButton(
                      tooltip: _showKey ? '隐藏 API Key' : '显示 API Key',
                      onPressed: () => setState(() => _showKey = !_showKey),
                      icon: Icon(
                        _showKey ? LucideIcons.eye_off : LucideIcons.eye,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                if (_keyConfigured)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _saving ? null : _clearKey,
                      child: const Text('清除已存 Key'),
                    ),
                  ),
              ],
            ),
          ),
          const AppSectionLabel('模型', compact: true),
          SettingCard(
            child: TextField(
              key: const Key('stt-model'),
              controller: _modelController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '模型名称',
                prefixIcon: Icon(LucideIcons.box, size: 20),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: FilledButton(
              key: const Key('stt-save'),
              onPressed: _loading || _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    );
  }
}
