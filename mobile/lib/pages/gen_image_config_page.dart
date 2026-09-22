import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/media_config_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

class GenImageConfigPage extends StatefulWidget {
  const GenImageConfigPage({super.key, this.mediaConfigApi});

  final MediaConfigApi? mediaConfigApi;

  @override
  State<GenImageConfigPage> createState() => _GenImageConfigPageState();
}

class _GenImageConfigPageState extends State<GenImageConfigPage> {
  static const List<String> _standardSizes = [
    '512x512',
    '768x768',
    '1024x1024',
    '1280x1280',
  ];

  late final MediaConfigApi _api;
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  late final TextEditingController _modelController;
  String _imageSize = '1024x1024';
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
    final snapshot = await _api.load(onCache: _applySnapshot);
    _applySnapshot(snapshot);
    if (mounted) setState(() => _loading = false);
  }

  void _applySnapshot(MediaConfigSnapshot snapshot) {
    if (!mounted) return;
    final config = snapshot.image;
    setState(() {
      _urlController.text = config.apiUrl;
      _modelController.text = config.model;
      _keyController.clear();
      _imageSize = config.imageSize.isEmpty ? '1024x1024' : config.imageSize;
      _keyConfigured = config.keyConfigured;
    });
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
        MediaFeature.image,
        apiUrl: _urlController.text,
        model: _modelController.text,
        imageSize: _imageSize,
        apiKey: newKey,
        updateApiKey: newKey.isNotEmpty,
      );
      _applySnapshot(snapshot);
      _showMessage('图片生成配置已保存');
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
        MediaFeature.image,
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
    final sizes = <String>{..._standardSizes, _imageSize}.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('图片生成')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          const AppSectionLabel('连接', compact: true),
          SettingCard(
            child: Column(
              children: [
                TextField(
                  key: const Key('image-api-url'),
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
                  key: const Key('image-api-key'),
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
          const AppSectionLabel('模型与尺寸', compact: true),
          SettingCard(
            child: Column(
              children: [
                TextField(
                  key: const Key('image-model'),
                  controller: _modelController,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    prefixIcon: Icon(LucideIcons.box, size: 20),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                DropdownButtonFormField<String>(
                  key: ValueKey('image-size-$_imageSize'),
                  initialValue: _imageSize,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '图片尺寸',
                    prefixIcon: Icon(LucideIcons.ratio, size: 20),
                  ),
                  items: [
                    for (final size in sizes)
                      DropdownMenuItem(
                        value: size,
                        child: Text(size.replaceFirst('x', ' × ')),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _imageSize = value);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: FilledButton(
              key: const Key('image-save'),
              onPressed: _loading || _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    );
  }
}
