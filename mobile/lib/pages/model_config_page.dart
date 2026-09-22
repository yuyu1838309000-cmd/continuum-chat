import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/chat_api.dart';
import '../utils/app_theme.dart';
import '../utils/token_usage.dart';
import '../widgets/setting_card.dart';
import '../widgets/swipe_back.dart';

/// 供应商静态信息：图标 + 名称兜底。
class _ProviderMeta {
  final IconData icon;
  final String fallbackName;

  const _ProviderMeta(this.icon, this.fallbackName);
}

const Map<String, _ProviderMeta> _providerMeta = {
  'deepseek': _ProviderMeta(LucideIcons.brain_cog, 'DeepSeek'),
  'gemini': _ProviderMeta(LucideIcons.sparkles, 'Gemini'),
  'openrouter': _ProviderMeta(LucideIcons.route, 'OpenRouter'),
  'custom': _ProviderMeta(LucideIcons.sliders_horizontal, '自定义'),
};

/// DeepSeek reasoning_effort 档位（表单只放 low/high/max；thinking 关时不显示，
/// 服务端 off/xhigh 仅作老配置兼容）。
const List<String> _deepseekEfforts = ['low', 'high', 'max'];

/// Gemini thinkingLevel 档位（OpenAI 兼容端点 thinkingConfig.thinkingLevel）。
const List<String> _geminiLevels = ['MINIMAL', 'LOW', 'MEDIUM', 'HIGH'];

/// 模型配置页 v3：
/// - 列表页以供应商名、当前模型和是否正在使用为主；
/// - 表单页聚合为连接、动态模型、生成设置三张主卡，DeepSeek 余额降权保留；
/// - 四类供应商统一通过 /models/discover 实时获取模型，当前保存值与手填兜底始终保留。
/// 数据源 8816 GET/POST /model-config（~/model_config.json 多供应商结构），
/// 拉不到服务器时用本地缓存兜底（改动写服务器，失败提示不落盘）。
class ModelConfigPage extends StatefulWidget {
  const ModelConfigPage({super.key});

  @override
  State<ModelConfigPage> createState() => _ModelConfigPageState();
}

class _ModelConfigPageState extends State<ModelConfigPage> {
  static const String _cacheKey = 'model_config_cache_v2';

  Map<String, dynamic>? _cfg;
  bool _loading = true;
  bool _activating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final server = await ChatApi.fetchModelConfig();
    if (!mounted) return;
    Map<String, dynamic> cfg;
    if (server != null && server['providers'] is Map) {
      cfg = server;
      await prefs.setString(_cacheKey, jsonEncode(server));
    } else {
      cfg = _readCache(prefs) ?? _defaultCfg();
    }
    setState(() {
      _cfg = cfg;
      _loading = false;
    });
  }

  Map<String, dynamic>? _readCache(SharedPreferences prefs) {
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic> && j['providers'] is Map) return j;
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> _defaultCfg() => {
    'providers': {
      'deepseek': {
        'base_url': ChatApi.defaultBaseUrl,
        'model': ChatApi.defaultModel,
        'api_key': '',
        'temperature': 1.0,
        'top_p': 1.0,
        'max_tokens': null,
        'thinking': true,
        'reasoning_effort': 'high',
        'timeout': 60,
        'extra_params': const {},
        'configured': false,
      },
      'gemini': {
        'base_url': ChatApi.geminiBaseUrl,
        'model': ChatApi.geminiDefaultModel,
        'api_key': '',
        'temperature': 1.0,
        'top_p': 1.0,
        'top_k': null,
        'max_tokens': null,
        'thinking': true,
        'thinking_mode': 'level',
        'thinking_level': 'MEDIUM',
        'thinking_budget': null,
        'timeout': 60,
        'extra_params': const {},
        'configured': false,
      },
      'openrouter': {
        'base_url': ChatApi.openRouterBaseUrl,
        'model': '',
        'api_key': '',
        'temperature': 1.0,
        'top_p': 1.0,
        'max_tokens': null,
        'timeout': 60,
        'extra_params': const {},
        'configured': false,
      },
      'custom': {
        'name': '自定义',
        'base_url': '',
        'model': '',
        'api_key': '',
        'temperature': 1.0,
        'top_p': 1.0,
        'max_tokens': null,
        'timeout': 60,
        'extra_params': const {},
        'configured': false,
      },
    },
    'active': 'deepseek',
  };

  Map<dynamic, dynamic> get _providers =>
      (_cfg?['providers'] as Map?) ?? const {};

  /// 展示顺序：预置四家在前，追加的自定义（custom_2/3…）按名字排在后。
  List<String> _orderedIds() {
    final ids = _providers.keys.map((e) => e.toString()).toList();
    const preset = ['deepseek', 'gemini', 'openrouter', 'custom'];
    final ordered = <String>[];
    for (final p in preset) {
      if (ids.contains(p)) ordered.add(p);
    }
    final extras = ids.where((id) => !preset.contains(id)).toList()..sort();
    ordered.addAll(extras);
    return ordered;
  }

  String _providerName(String id, Map data) {
    final n = data['name'];
    if (n is String && n.trim().isNotEmpty) return n.trim();
    return _providerMeta[id]?.fallbackName ?? '自定义';
  }

  Future<void> _activate(String id) async {
    if (_activating || _cfg?['active'] == id) return;
    setState(() => _activating = true);
    try {
      final pub = await ChatApi.saveProviderConfig(id, const {}, active: id);
      if (!mounted) return;
      setState(() => _cfg = pub);
    } on Exception catch (e) {
      if (!mounted) return;
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _activating = false);
    }
  }

  Future<void> _openForm(String id) async {
    final data = Map<String, dynamic>.from(_providers[id] as Map? ?? const {});
    final changed = await Navigator.of(context).push<bool>(
      SwipeBackRoute(
        builder: (_) => _ProviderFormPage(
          providerId: id,
          name: _providerName(id, data),
          data: data,
        ),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _addCustom() async {
    var n = 2;
    while (_providers.containsKey('custom_$n')) {
      n++;
    }
    final id = 'custom_$n';
    final changed = await Navigator.of(context).push<bool>(
      SwipeBackRoute(
        builder: (_) => _ProviderFormPage(
          providerId: id,
          name: '自定义 $n',
          data: {
            'name': '自定义 $n',
            'base_url': '',
            'model': '',
            'api_key': '',
            'temperature': 1.0,
            'top_p': 1.0,
            'max_tokens': null,
            'timeout': 60,
            'extra_params': const {},
          },
        ),
      ),
    );
    if (changed == true) _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 13)),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型配置'),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(LucideIcons.refresh_cw, size: 20),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
              children: [
                for (final id in _orderedIds()) _providerCard(id),
                _addCard(),
                _tokenUsageCard(),
              ],
            ),
    );
  }

  Widget _providerCard(String id) {
    final data = _providers[id] as Map? ?? const {};
    final active = _cfg?['active'] == id;
    final meta =
        _providerMeta[id] ??
        const _ProviderMeta(LucideIcons.sliders_horizontal, '自定义');
    final name = _providerName(id, data);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openForm(id),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.fieldColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(meta.icon, size: 22, color: context.subTextColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (data['model'] as String? ?? '').trim().isEmpty
                            ? '未选择模型'
                            : (data['model'] as String).trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.subTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (active) _activeBadge() else _enableButton(id),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _activeBadge() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: context.accentColor,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.check, size: 14, color: theme.colorScheme.onPrimary),
          const SizedBox(width: 4),
          Text(
            '当前使用中',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// 非启用供应商的「启用」胶囊按钮（中性色，全页主色只留给启用中徽标）。
  Widget _enableButton(String id) {
    if (_activating) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.full),
      onTap: () => _activate(id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: context.fieldColor,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Text(
          '启用',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.textColor,
          ),
        ),
      ),
    );
  }

  Widget _addCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _addCustom,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.fieldColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    LucideIcons.plus,
                    size: 22,
                    color: context.subTextColor,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  '添加自定义供应商',
                  style: TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tokenUsageCard() {
    return SettingCard(
      padding: EdgeInsets.zero,
      child: ValueListenableBuilder<bool>(
        valueListenable: TokenUsagePref.show,
        builder: (context, value, _) => SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          secondary: Icon(
            LucideIcons.gauge,
            size: 24,
            color: context.subTextColor,
          ),
          title: const Text(
            '显示 token 用量',
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          value: value,
          onChanged: (v) {
            TokenUsagePref.set(v);
          },
        ),
      ),
    );
  }
}

/// 单个供应商专属配置表单。
/// 字段随供应商不同：DeepSeek / Gemini / OpenRouter / 自定义，
/// 所有表单都带 temperature/top_p/max_tokens/超时秒数/额外参数 JSON/测试连接。
class _ProviderFormPage extends StatefulWidget {
  final String providerId;
  final String name;
  final Map<String, dynamic> data;

  const _ProviderFormPage({
    required this.providerId,
    required this.name,
    required this.data,
  });

  @override
  State<_ProviderFormPage> createState() => _ProviderFormPageState();
}

class _ProviderFormPageState extends State<_ProviderFormPage> {
  static const String _customModelValue = '__custom__';

  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _maxTokensCtrl;
  late final TextEditingController _topKCtrl;
  late final TextEditingController _thinkingBudgetCtrl;
  late final TextEditingController _timeoutCtrl;
  late final TextEditingController _extraJsonCtrl;

  bool _showKey = false;
  bool _saving = false;
  bool _hasServerKey = false;
  bool _clearKey = false;

  bool _thinking = true;
  String _reasoningEffort = 'high';
  String _geminiMode = 'level';
  String _geminiLevel = 'MEDIUM';
  int? _thinkingBudget;
  double _temperature = 1.0;
  double _topP = 1.0;
  int? _maxTokens;
  int _timeout = 60;
  Map<String, dynamic> _extraParams = const {};

  bool _customModel = false;
  String _selectedPreset = '';
  String _savedModel = '';
  List<String> _discoveredModels = const [];
  bool _modelsLoading = false;
  String? _modelsError;
  int? _modelsLatencyMs;

  Map<String, dynamic>? _balance;
  bool _balanceLoading = false;
  bool _testing = false;
  Map<String, dynamic>? _testResult;

  bool get _isDeepseek => widget.providerId == 'deepseek';
  bool get _isGemini => widget.providerId == 'gemini';
  bool get _isOpenRouter => widget.providerId == 'openrouter';
  bool get _isCustom =>
      widget.providerId == 'custom' || widget.providerId.startsWith('custom_');

  List<String> get _modelCandidates {
    final seen = <String>{};
    return [
      _savedModel,
      if (!_customModel) _selectedPreset,
      ..._discoveredModels,
    ].where((model) => model.isNotEmpty && seen.add(model)).toList();
  }

  String get _defaultBaseUrl {
    if (_isDeepseek) return ChatApi.defaultBaseUrl;
    if (_isGemini) return ChatApi.geminiBaseUrl;
    if (_isOpenRouter) return ChatApi.openRouterBaseUrl;
    return '';
  }

  @override
  void initState() {
    super.initState();
    _baseUrlCtrl = TextEditingController();
    _apiKeyCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _nameCtrl = TextEditingController();
    _maxTokensCtrl = TextEditingController();
    _topKCtrl = TextEditingController();
    _thinkingBudgetCtrl = TextEditingController();
    _timeoutCtrl = TextEditingController();
    _extraJsonCtrl = TextEditingController();
    _initFields();
    unawaited(_discoverModels());
    if (_isDeepseek) _loadBalance();
  }

  void _initFields() {
    final d = widget.data;
    _hasServerKey = (d['api_key'] as String? ?? '').isNotEmpty;
    _baseUrlCtrl.text = (d['base_url'] as String? ?? _defaultBaseUrl).trim();
    _nameCtrl.text = (d['name'] as String? ?? '').trim();

    final model = (d['model'] as String? ?? '').trim();
    final fallback = _isDeepseek
        ? ChatApi.defaultModel
        : _isGemini
        ? ChatApi.geminiDefaultModel
        : '';
    _savedModel = model.isEmpty ? fallback : model;
    _selectedPreset = _savedModel;
    _customModel = _savedModel.isEmpty;
    _modelCtrl.text = _savedModel;

    _thinking = d['thinking'] == null ? true : d['thinking'] == true;
    final effortRaw = (d['reasoning_effort'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (effortRaw == 'off') {
      // 老配置 off = 关思考，归一化成表单的 low + 开关关闭
      _thinking = false;
      _reasoningEffort = 'low';
    } else {
      _reasoningEffort = _normalizeDeepseekEffort(effortRaw);
    }

    _geminiMode = (d['thinking_mode'] as String? ?? 'level') == 'budget'
        ? 'budget'
        : 'level';
    final level = (d['thinking_level'] as String? ?? '').toUpperCase();
    _geminiLevel = _geminiLevels.contains(level) ? level : 'MEDIUM';
    _thinkingBudget = (d['thinking_budget'] as num?)?.toInt();
    _thinkingBudgetCtrl.text = _thinkingBudget?.toString() ?? '';

    _temperature = (d['temperature'] as num?)?.toDouble() ?? 1.0;
    _topP = (d['top_p'] as num?)?.toDouble() ?? 1.0;
    _maxTokens = (d['max_tokens'] as num?)?.toInt();
    _maxTokensCtrl.text = _maxTokens?.toString() ?? '';

    final topK = (d['top_k'] as num?)?.toInt();
    _topKCtrl.text = (topK == null || topK <= 0) ? '' : topK.toString();

    _timeout = ((d['timeout'] as num?)?.toInt() ?? 60).clamp(5, 600);
    _timeoutCtrl.text = _timeout.toString();

    final ex = d['extra_params'];
    if (ex is Map && ex.isNotEmpty) {
      _extraParams = Map<String, dynamic>.from(ex);
      _extraJsonCtrl.text = const JsonEncoder.withIndent(
        '  ',
      ).convert(_extraParams);
    } else {
      _extraParams = const {};
      _extraJsonCtrl.text = '';
    }
  }

  String _normalizeDeepseekEffort(Object? value) {
    final s = (value ?? '').toString().trim().toLowerCase();
    return _deepseekEfforts.contains(s) ? s : 'high';
  }

  int? _parseOptionalInt(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  Map<String, dynamic>? _parseExtraJson() {
    final t = _extraJsonCtrl.text.trim();
    if (t.isEmpty) return {};
    try {
      final j = jsonDecode(t);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return null;
  }

  String _effectiveModel() {
    return _customModel ? _modelCtrl.text.trim() : _selectedPreset.trim();
  }

  String _modelDropdownValue() {
    if (_customModel) return _customModelValue;
    if (_modelCandidates.contains(_selectedPreset)) return _selectedPreset;
    return _customModelValue;
  }

  void _onModelDropdownChanged(String? value) {
    if (value == null) return;
    setState(() {
      if (value == _customModelValue) {
        _customModel = true;
      } else {
        _customModel = false;
        _selectedPreset = value;
        _modelCtrl.text = value;
      }
    });
  }

  Future<void> _discoverModels() async {
    if (_modelsLoading) return;
    setState(() {
      _modelsLoading = true;
      _modelsError = null;
    });
    final response = await ChatApi.discoverModels(
      widget.providerId,
      _collectFields(),
    );
    if (!mounted) return;
    if (response?['ok'] == true && response?['models'] is List) {
      final seen = <String>{};
      final models = [
        for (final value in response!['models'] as List)
          if (value is String && value.trim().isNotEmpty) value.trim(),
      ].where(seen.add).toList();
      setState(() {
        _discoveredModels = models;
        _modelsLatencyMs = (response['latency_ms'] as num?)?.toInt();
        _modelsLoading = false;
      });
      return;
    }
    setState(() {
      _modelsLoading = false;
      _modelsError = (response?['error'] as String?)?.trim().isNotEmpty == true
          ? (response!['error'] as String).trim()
          : '暂时无法获取在线模型';
    });
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _nameCtrl.dispose();
    _maxTokensCtrl.dispose();
    _topKCtrl.dispose();
    _thinkingBudgetCtrl.dispose();
    _timeoutCtrl.dispose();
    _extraJsonCtrl.dispose();
    super.dispose();
  }

  /// 组装保存/测试共用的字段（api_key 没输入时不带 = 服务器保留原 key；
  /// 点过「清除已存 key」则显式传空串）。
  Map<String, dynamic> _collectFields() {
    final fields = <String, dynamic>{};
    if (_isCustom) fields['name'] = _nameCtrl.text.trim();
    fields['base_url'] = _baseUrlCtrl.text.trim().isEmpty
        ? _defaultBaseUrl
        : _baseUrlCtrl.text.trim();

    final model = _effectiveModel();
    if (model.isEmpty) {
      fields['model'] = _isDeepseek
          ? ChatApi.defaultModel
          : _isGemini
          ? ChatApi.geminiDefaultModel
          : '';
    } else {
      fields['model'] = model;
    }
    fields['temperature'] = _temperature;
    fields['top_p'] = _topP;
    fields['max_tokens'] = _parseOptionalInt(_maxTokensCtrl.text);
    fields['timeout'] = _parseOptionalInt(_timeoutCtrl.text) ?? 60;
    fields['extra_params'] = _parseExtraJson() ?? const {};

    if (_isDeepseek) {
      fields['thinking'] = _thinking;
      fields['reasoning_effort'] = _reasoningEffort;
    } else if (_isGemini) {
      fields['top_k'] = _parseOptionalInt(_topKCtrl.text);
      fields['thinking'] = _thinking;
      fields['thinking_mode'] = _geminiMode;
      fields['thinking_level'] = _geminiLevel;
      fields['thinking_budget'] = _parseOptionalInt(_thinkingBudgetCtrl.text);
    }

    final keyInput = _apiKeyCtrl.text.trim();
    if (keyInput.isNotEmpty) {
      fields['api_key'] = keyInput;
    } else if (_clearKey) {
      fields['api_key'] = '';
    }
    return fields;
  }

  Future<void> _save() async {
    if (_parseExtraJson() == null) {
      _toast('额外参数 JSON 格式不对');
      return;
    }
    final fields = _collectFields();
    setState(() => _saving = true);
    try {
      await ChatApi.saveProviderConfig(widget.providerId, fields);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _test() async {
    if (_parseExtraJson() == null) {
      _toast('额外参数 JSON 格式不对');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final res = await ChatApi.testConnection(
      widget.providerId,
      _collectFields(),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = res;
    });
    if (res == null) {
      _toast('连不上服务器，测试没发出去');
    } else if (res['ok'] == true) {
      _toast('连接成功 · ${res['latency_ms'] ?? '-'} ms');
    } else {
      _toast((res['error'] as String?) ?? '连接失败');
    }
  }

  Future<void> _delete() async {
    final isExtraCustom = _isCustom && widget.providerId != 'custom';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isExtraCustom ? '删除供应商' : '清空配置'),
        content: Text(
          isExtraCustom
              ? '删除「${widget.name}」后不可恢复，确定吗？'
              : '清空「${widget.name}」的配置（回默认），确定吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: context.dangerColor),
            child: Text(isExtraCustom ? '删除' : '清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await ChatApi.saveProviderConfig(
        widget.providerId,
        const {},
        deleteProvider: true,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _loadBalance() async {
    setState(() => _balanceLoading = true);
    final b = await ChatApi.fetchBalance();
    if (!mounted) return;
    setState(() {
      _balance = b;
      _balanceLoading = false;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 13)),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        actions: [
          IconButton(
            tooltip: _isCustom && widget.providerId != 'custom'
                ? '删除供应商'
                : '清空配置',
            onPressed: _saving ? null : _delete,
            icon: const Icon(LucideIcons.trash_2, size: 20),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          _connectionCard(),
          _modelSection(),
          _generationCard(),
          if (_isDeepseek) _balanceSection(),
          _saveButton(),
        ],
      ),
    );
  }

  Widget _cardHeading(String text, {Widget? trailing}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }

  /// 表单输入框统一样式（fieldColor 底 + 圆角 14 + 无描边），
  /// 各表单字段共用，保持卡片内视觉一致。
  InputDecoration _inputDecoration({
    String? label,
    String? hint,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: context.fieldColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    required IconData icon,
    String? hint,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: ctrl,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: keyboardType,
      decoration: _inputDecoration(label: label, hint: hint, icon: icon),
    );
  }

  Widget _connectionCard() {
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeading('连接'),
          const SizedBox(height: AppSpacing.md),
          if (_isCustom) ...[
            _field('名称', _nameCtrl, icon: LucideIcons.tag, hint: '自定义供应商名称'),
            const SizedBox(height: AppSpacing.sm),
          ],
          _field(
            '服务地址',
            _baseUrlCtrl,
            icon: LucideIcons.link,
            hint: _defaultBaseUrl.isEmpty
                ? '例如 http://127.0.0.1:11434/v1'
                : _defaultBaseUrl,
          ),
          const SizedBox(height: AppSpacing.sm),
          _apiKeyField(),
          const SizedBox(height: AppSpacing.md),
          _testSection(),
        ],
      ),
    );
  }

  Widget _apiKeyField() {
    return Column(
      children: [
        TextField(
          controller: _apiKeyCtrl,
          obscureText: !_showKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: _inputDecoration(
            label: 'API Key',
            hint: _hasServerKey
                ? (_clearKey ? '保存后将清除服务器 key' : '已配置，留空保持原 key')
                : '输入 API Key',
            icon: LucideIcons.key,
            suffixIcon: IconButton(
              icon: Icon(
                _showKey ? LucideIcons.eye_off : LucideIcons.eye,
                size: 20,
              ),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
        if (_hasServerKey)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _clearKey = !_clearKey),
              child: Text(
                _clearKey ? '取消清除' : '清除已存 key',
                style: TextStyle(fontSize: 12, color: context.subTextColor),
              ),
            ),
          ),
      ],
    );
  }

  /// 在线模型列表只来自 /models/discover；当前保存值始终额外保留。
  Widget _modelSection() {
    final candidates = _modelCandidates;
    final dropdownKey = '${_modelDropdownValue()}|${candidates.join('|')}';
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeading(
            '模型',
            trailing: _modelsLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: '刷新在线模型',
                    onPressed: _discoverModels,
                    icon: const Icon(LucideIcons.refresh_cw, size: 20),
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (candidates.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey(dropdownKey),
              initialValue: _modelDropdownValue(),
              isExpanded: true,
              menuMaxHeight: 360,
              decoration: _inputDecoration(
                label: '当前模型',
                icon: LucideIcons.brain_cog,
              ),
              items: [
                for (final model in candidates)
                  DropdownMenuItem(
                    value: model,
                    child: Text(
                      model,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const DropdownMenuItem(
                  value: _customModelValue,
                  child: Text('手动输入…', style: TextStyle(fontSize: 13)),
                ),
              ],
              onChanged: _onModelDropdownChanged,
            ),
          if (_customModel || candidates.isEmpty) ...[
            if (candidates.isNotEmpty) const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _modelCtrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: _inputDecoration(
                label: '手动输入模型',
                icon: LucideIcons.keyboard,
                hint: _isOpenRouter ? '例如 openai/gpt-4.1-mini' : '模型 ID',
              ),
            ),
          ],
          if (_modelsError case final error?) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Icon(
                  LucideIcons.circle_alert,
                  size: 16,
                  color: context.dangerColor,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: context.dangerColor),
                  ),
                ),
                TextButton(onPressed: _discoverModels, child: const Text('重试')),
              ],
            ),
          ] else if (_discoveredModels.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '已发现 ${_discoveredModels.length} 个在线模型'
              '${_modelsLatencyMs == null ? '' : ' · ${_modelsLatencyMs}ms'}',
              style: TextStyle(fontSize: 12, color: context.subTextColor),
            ),
          ],
        ],
      ),
    );
  }

  Widget _thinkingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(LucideIcons.brain),
          title: Text(_isDeepseek ? 'DeepSeek 思考' : 'Gemini 思考'),
          value: _thinking,
          onChanged: (v) => setState(() => _thinking = v),
        ),
        if (_thinking) ...[
          const SizedBox(height: 4),
          if (_isDeepseek) _deepseekEffortDropdown(),
          if (_isGemini) ...[
            _geminiModeSelector(),
            const SizedBox(height: 12),
            if (_geminiMode == 'level') _geminiLevelDropdown(),
            if (_geminiMode == 'budget') _geminiBudgetField(),
          ],
        ],
      ],
    );
  }

  Widget _deepseekEffortDropdown() {
    const labels = {'low': '低', 'high': '高', 'max': '最大'};
    final value = _deepseekEfforts.contains(_reasoningEffort)
        ? _reasoningEffort
        : 'high';
    return DropdownButtonFormField<String>(
      key: ValueKey(value),
      initialValue: value,
      isExpanded: true,
      decoration: _inputDecoration(icon: LucideIcons.sliders_horizontal),
      items: [
        for (final e in _deepseekEfforts)
          DropdownMenuItem(
            value: e,
            child: Text(
              'reasoning_effort · ${labels[e]}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) setState(() => _reasoningEffort = v);
      },
    );
  }

  Widget _geminiModeSelector() {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'level', label: Text('thinkingLevel')),
        ButtonSegment(value: 'budget', label: Text('thinkingBudget')),
      ],
      selected: {_geminiMode},
      showSelectedIcon: false,
      onSelectionChanged: (s) => setState(() => _geminiMode = s.first),
    );
  }

  Widget _geminiLevelDropdown() {
    return DropdownButtonFormField<String>(
      key: ValueKey(_geminiLevel),
      initialValue: _geminiLevel,
      isExpanded: true,
      decoration: _inputDecoration(icon: LucideIcons.brain_cog),
      items: [
        for (final l in _geminiLevels)
          DropdownMenuItem(
            value: l,
            child: Text(l, style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: (v) {
        if (v != null) setState(() => _geminiLevel = v);
      },
    );
  }

  Widget _geminiBudgetField() {
    return TextField(
      controller: _thinkingBudgetCtrl,
      keyboardType: TextInputType.number,
      autocorrect: false,
      enableSuggestions: false,
      decoration: _inputDecoration(
        icon: LucideIcons.hash,
        hint: 'thinkingBudget token 数（空 = 官方默认）',
      ),
    );
  }

  Widget _paramsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SliderInputTile(
          icon: LucideIcons.thermometer,
          title: 'temperature',
          value: _temperature,
          min: 0,
          max: 2,
          decimalPlaces: 1,
          onChanged: (v) => setState(() => _temperature = v),
        ),
        _SliderInputTile(
          icon: LucideIcons.percent,
          title: 'top_p',
          value: _topP,
          min: 0,
          max: 1,
          decimalPlaces: 2,
          onChanged: (v) => setState(() => _topP = v),
        ),
      ],
    );
  }

  Widget _generationCard() {
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeading('生成设置'),
          const SizedBox(height: AppSpacing.sm),
          _paramsSection(),
          if (_isGemini) ...[
            _topKField(),
            const SizedBox(height: AppSpacing.sm),
          ],
          _maxTokensField(),
          if (_isDeepseek || _isGemini) ...[
            const SizedBox(height: AppSpacing.sm),
            _thinkingSection(),
          ],
          const SizedBox(height: AppSpacing.xs),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('provider-advanced-settings'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: AppSpacing.xs),
              title: Text(
                '高级',
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w600,
                  color: context.subTextColor,
                ),
              ),
              children: [
                _timeoutField(),
                const SizedBox(height: AppSpacing.sm),
                _extraJsonField(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topKField() {
    return _field(
      'top_k（空 = 官方默认）',
      _topKCtrl,
      icon: LucideIcons.arrow_up_narrow_wide,
      hint: '例如 40',
      keyboardType: TextInputType.number,
    );
  }

  Widget _maxTokensField() {
    return _field(
      _isGemini
          ? 'max_tokens（对应 maxOutputTokens，空 = 不限制）'
          : 'max_tokens（空 = 不限制）',
      _maxTokensCtrl,
      icon: LucideIcons.hash,
      hint: '例如 4096',
      keyboardType: TextInputType.number,
    );
  }

  Widget _timeoutField() {
    return _field(
      '超时秒数（5-600，空 = 60）',
      _timeoutCtrl,
      icon: LucideIcons.timer,
      hint: '60',
      keyboardType: TextInputType.number,
    );
  }

  Widget _extraJsonField() {
    return TextField(
      controller: _extraJsonCtrl,
      minLines: 4,
      maxLines: 8,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 13),
      decoration: _inputDecoration(
        label: '额外参数 JSON',
        icon: LucideIcons.braces,
        hint: '例如 {"seed": 42}',
      ),
    );
  }

  Widget _testSection() {
    final result = _testResult;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.plug_zap, size: 18),
            label: Text(_testing ? '测试中…' : '测试连接'),
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          _testResultCard(result),
        ],
      ],
    );
  }

  Widget _testResultCard(Map<String, dynamic> r) {
    final ok = r['ok'] == true;
    final status = r['status'];
    final latency = r['latency_ms'];
    final model = r['model'];
    final text = ok
        ? '连接成功 · ${latency ?? '-'}ms · ${model ?? ''}'
        : ((r['error'] as String?) ?? '连接失败');
    final color = ok ? context.successColor : context.dangerColor;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? LucideIcons.circle_check : LucideIcons.circle_x,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13, color: color)),
          ),
          if (status != null)
            Text(
              'HTTP $status',
              style: TextStyle(
                fontSize: 12,
                color: color.withValues(alpha: 0.8),
              ),
            ),
        ],
      ),
    );
  }

  Widget _balanceSection() {
    final theme = Theme.of(context);
    final hasBalance = _balance != null;
    final balanceTitle = hasBalance ? '¥ ${_balance!['totalBalance']}' : '查询失败';
    final balanceMeta = hasBalance
        ? '${_balance!['currency']} · 可用：${_balance!['available'] == true ? '是' : '否'}'
        : '刷新后显示余额';
    return SettingCard(
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.fieldColor,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              LucideIcons.wallet,
              size: 18,
              color: context.subTextColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DeepSeek 余额 · $balanceTitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  balanceMeta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _balanceLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(LucideIcons.refresh_cw),
                  tooltip: '刷新余额',
                  onPressed: _loadBalance,
                ),
        ],
      ),
    );
  }

  Widget _saveButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SizedBox(
        height: 48,
        child: FilledButton(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ),
    );
  }
}

/// slider + 数字输入框联动（照旧模型配置页实现）。
class _SliderInputTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int decimalPlaces;
  final ValueChanged<double> onChanged;

  const _SliderInputTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.decimalPlaces,
    required this.onChanged,
  });

  @override
  State<_SliderInputTile> createState() => _SliderInputTileState();
}

class _SliderInputTileState extends State<_SliderInputTile> {
  late final TextEditingController _ctrl;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _fmt(widget.value));
  }

  @override
  void didUpdateWidget(covariant _SliderInputTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _fmt(double v) {
    final fixed = v.toStringAsFixed(widget.decimalPlaces);
    return fixed.contains('.')
        ? fixed
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceFirst(RegExp(r'\.$'), '')
        : fixed;
  }

  void _onSlider(double v) {
    widget.onChanged(v);
    if (!_focus.hasFocus) {
      _ctrl.text = _fmt(v);
    }
  }

  void _onText(String s) {
    final v = double.tryParse(s.trim());
    if (v == null) return;
    final clamped = v.clamp(widget.min, widget.max);
    widget.onChanged(clamped);
    if (clamped != v) {
      _ctrl.text = _fmt(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(widget.icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              widget.title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 72,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                onChanged: _onText,
                onTapOutside: (_) => _focus.unfocus(),
                onEditingComplete: () {
                  _focus.unfocus();
                  final v = double.tryParse(_ctrl.text.trim());
                  if (v != null) {
                    _ctrl.text = _fmt(v.clamp(widget.min, widget.max));
                  } else {
                    _ctrl.text = _fmt(widget.value);
                  }
                },
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.primaryContainer,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: widget.value.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: (widget.max - widget.min) * 20 ~/ 1,
          label: _fmt(widget.value),
          onChanged: _onSlider,
        ),
      ],
    );
  }
}
