import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/tts_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// TTS 配置页：adapter-aware 的语音服务配置。
/// 当前运行时只实现 T2A v2 adapter；地址、模型、Key、音色与语速均可配置。
class TtsConfigPage extends StatefulWidget {
  const TtsConfigPage({super.key});

  @override
  State<TtsConfigPage> createState() => _TtsConfigPageState();
}

class _TtsConfigPageState extends State<TtsConfigPage> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _voiceCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _speedCtrl;
  late final TextEditingController _previewCtrl;
  bool _showKey = false;
  TtsAudioCacheStats? _cacheStats;
  bool _loadingCacheStats = false;

  bool get _previewing =>
      TtsPlayer.instance.playing &&
      TtsPlayer.instance.currentText == _previewCtrl.text;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController();
    _voiceCtrl = TextEditingController();
    _urlCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _speedCtrl = TextEditingController();
    _previewCtrl = TextEditingController(text: 'AI 助手在呢，用户想听我说话了吗？');
    _load();
  }

  Future<void> _load() async {
    await TtsConfig.instance.load();
    if (!mounted) return;
    setState(() {
      _keyCtrl.text = TtsConfig.instance.apiKey;
      _voiceCtrl.text = TtsConfig.instance.voiceId;
      _urlCtrl.text = TtsConfig.instance.apiUrl;
      _modelCtrl.text = TtsConfig.instance.model;
      _speedCtrl.text = TtsConfig.instance.speed.toStringAsFixed(2);
    });
    await _loadCacheStats();
  }

  Future<void> _loadCacheStats() async {
    if (_loadingCacheStats) return;
    _loadingCacheStats = true;
    final stats = await TtsAudioCache.stats();
    _loadingCacheStats = false;
    if (!mounted) return;
    setState(() => _cacheStats = stats);
  }

  Future<void> _clearCache() async {
    await TtsAudioCache.clear();
    await _loadCacheStats();
  }

  Future<void> _saveSpeedText(String value) async {
    final speed = double.tryParse(value.trim());
    if (speed == null || speed < 0.5 || speed > 1.5) {
      _speedCtrl.text = TtsConfig.instance.speed.toStringAsFixed(2);
      return;
    }
    await TtsConfig.instance.setSpeed(speed);
  }

  Future<void> _preview() async {
    final player = TtsPlayer.instance;
    await player.toggle(_previewCtrl.text);
    await _loadCacheStats();
    if (player.lastError != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              player.lastError!,
              style: const TextStyle(fontSize: 13),
            ),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  String _adapterLabel(String adapter) => switch (adapter) {
    TtsConfig.defaultAdapter => 'T2A v2',
    _ => adapter,
  };

  InputDecoration _fieldDecoration(
    BuildContext context, {
    required String label,
    required IconData icon,
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: context.fieldColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _voiceCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _speedCtrl.dispose();
    _previewCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TTS')),
      body: ListenableBuilder(
        listenable: TtsConfig.instance,
        builder: (context, _) {
          final cfg = TtsConfig.instance;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              SettingCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    LucideIcons.volume_2,
                    size: 24,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: const Text('朗读'),
                  subtitle: const Text('让回复可以直接播放成语音'),
                  value: cfg.readAloud,
                  onChanged: cfg.setReadAloud,
                ),
              ),
              _serviceCard(context, cfg),
              _voiceCard(context, cfg),
              _previewCard(context),
            ],
          );
        },
      ),
    );
  }

  Widget _serviceCard(BuildContext context, TtsConfig cfg) {
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '语音服务',
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '当前协议：${_adapterLabel(cfg.adapter)}',
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _urlCtrl,
            onChanged: cfg.setApiUrl,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _fieldDecoration(
              context,
              label: '服务地址',
              icon: LucideIcons.globe,
              hint: '留空使用服务器默认地址',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _modelCtrl,
            onChanged: cfg.setModel,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _fieldDecoration(
              context,
              label: '模型',
              icon: LucideIcons.memory_stick,
              hint: '输入模型 ID',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _keyCtrl,
            onChanged: cfg.setApiKey,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _fieldDecoration(
              context,
              label: 'API Key',
              icon: LucideIcons.key,
              hint: '留空使用服务器已配置的 Key',
              suffixIcon: IconButton(
                tooltip: _showKey ? '隐藏 API Key' : '显示 API Key',
                icon: Icon(
                  _showKey ? LucideIcons.eye_off : LucideIcons.eye,
                  size: 20,
                ),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _voiceCard(BuildContext context, TtsConfig cfg) {
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '声音',
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _voiceCtrl,
            onChanged: cfg.setVoiceId,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _fieldDecoration(
              context,
              label: '音色 / Voice ID',
              icon: LucideIcons.mic,
              hint: '留空使用服务器默认声音',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              const Icon(LucideIcons.gauge, size: 18),
              const SizedBox(width: AppSpacing.sm),
              const Text('语速'),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Slider(
                  value: cfg.speed.clamp(0.5, 1.5),
                  min: 0.5,
                  max: 1.5,
                  divisions: 20,
                  onChanged: (value) {
                    cfg.setSpeed(value);
                    _speedCtrl.text = value.toStringAsFixed(2);
                  },
                ),
              ),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _speedCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  onChanged: _saveSpeedText,
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 'x',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewCard(BuildContext context) {
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '试听',
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _previewCtrl,
            maxLines: 2,
            decoration: _fieldDecoration(
              context,
              label: '试听内容',
              icon: LucideIcons.message_square_text,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: ListenableBuilder(
              listenable: TtsPlayer.instance,
              builder: (context, _) {
                final player = TtsPlayer.instance;
                return FilledButton.icon(
                  onPressed: player.loading ? null : _preview,
                  icon: Icon(
                    _previewing ? LucideIcons.square : LucideIcons.play,
                    size: 16,
                  ),
                  label: Text(_previewing ? '停止' : '试听当前声音'),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _CachePanel(
            stats: _cacheStats,
            onRefresh: _loadCacheStats,
            onClear: _clearCache,
          ),
        ],
      ),
    );
  }
}

class _CachePanel extends StatelessWidget {
  const _CachePanel({
    required this.stats,
    required this.onRefresh,
    required this.onClear,
  });

  final TtsAudioCacheStats? stats;
  final VoidCallback onRefresh;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.xs,
                children: [
                  _CacheMetric(label: '文件', value: '${s?.fileCount ?? 0}'),
                  _CacheMetric(label: '大小', value: s?.totalSizeLabel ?? '0 B'),
                  _CacheMetric(label: '命中', value: '${s?.hitCount ?? 0}'),
                  _CacheMetric(label: '未命中', value: '${s?.missCount ?? 0}'),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新缓存状态',
              onPressed: onRefresh,
              icon: const Icon(LucideIcons.refresh_cw, size: 18),
            ),
            IconButton(
              tooltip: '清空语音缓存',
              onPressed: onClear,
              icon: const Icon(LucideIcons.trash_2, size: 18),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          s?.lastOp ?? '尚无缓存操作',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.caption,
            color: context.subTextColor,
          ),
        ),
      ],
    );
  }
}

class _CacheMetric extends StatelessWidget {
  const _CacheMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.subTextColor),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
