import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/self_prompt_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 身份与性格编辑：记录希望AI 助手长期保持的身份、性格与交互方式。
/// 编辑区占满大半屏（大区域可滚动），保存/刷新走右上角。
/// 读写 8816 /self-prompt 的 system_prompt，服务端拼对话时
/// 作为【系统提示词】分区注入到 system 消息最顶上（最优先）。
class SelfPromptSystemPage extends StatefulWidget {
  const SelfPromptSystemPage({super.key});

  @override
  State<SelfPromptSystemPage> createState() => _SelfPromptSystemPageState();
}

class _SelfPromptSystemPageState extends State<SelfPromptSystemPage> {
  final TextEditingController _ctrl = TextEditingController();
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    final data = await SelfPromptApi.fetch();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (data == null) {
        _loadFailed = true;
      } else {
        _ctrl.text = data.systemPrompt;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final data = await SelfPromptApi.save(systemPrompt: _ctrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(data != null ? '已保存' : '保存失败，检查网络'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('身份与性格'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _saving ? null : _load,
            icon: const Icon(LucideIcons.refresh_cw),
          ),
          IconButton(
            tooltip: '保存',
            onPressed: _saving || _loading ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.save),
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('加载失败'),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    // 大编辑区：卡片占满剩余空间，TextField expands 全屏可滚动（同记忆页大半屏编辑模式）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SettingCard(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _ctrl,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 14, height: 1.6),
              decoration: InputDecoration(
                hintText: '写下希望AI 助手长期保持的身份、性格和交互方式……',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
                filled: true,
                fillColor: context.fieldColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
          child: Text(
            '保存后，AI 助手会在聊天中遵循这里的长期说明。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}
