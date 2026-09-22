import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/api_cache.dart';
import '../services/chat_api.dart';
import '../services/self_prompt_api.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 想记住的事：管理希望AI 助手长期记得的内容。
/// 读写 8816 /self-prompt 的 memories[]，可查看/添加/编辑/删除；
/// 卡片收起预览（maxLines 省略），添加/编辑弹**大半屏编辑卡片**
/// （参考聊天输入框展开：4/5 屏底部弹层，全屏大区域可滚动，返回不丢输入）。
/// 服务端拼对话时作为【记忆】分区注入（与 8820 召回记忆一起）。
class SelfPromptMemoryPage extends StatefulWidget {
  const SelfPromptMemoryPage({super.key});

  @override
  State<SelfPromptMemoryPage> createState() => _SelfPromptMemoryPageState();
}

class _SelfPromptMemoryPageState extends State<SelfPromptMemoryPage> {
  List<String> _memories = const [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;

  /// 编辑草稿：大半屏编辑卡片关闭（返回/下滑/取消）不丢输入，
  /// 草稿留在控制器里，下次打开自动带出；保存成功才清空。
  final TextEditingController _draftCtrl = TextEditingController();

  @override
  void dispose() {
    _draftCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），过期/无缓存才静默拉新；
  /// 手动刷新/重试走 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    final url = ServerConfig.url(8816, '/self-prompt');
    if (!force && _memories.isEmpty) {
      final cached = await ApiCache.read(url);
      final cachedMemories = _parseMemories(cached);
      if (!mounted) return;
      if (cachedMemories != null) {
        setState(() {
          _memories = cachedMemories;
          _loading = false;
          _loadFailed = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _memories.isEmpty;
      _loadFailed = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
      timeout: const Duration(seconds: 8),
    );
    final memories = _parseMemories(raw);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (memories != null) {
        _memories = memories;
        _loadFailed = false;
      } else if (_memories.isEmpty) {
        _loadFailed = true;
      }
    });
  }

  static List<String>? _parseMemories(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final list = raw['memories'];
    if (list is! List) return null;
    return [
      for (final m in list)
        if (m is String && m.trim().isNotEmpty) m.trim(),
    ];
  }

  /// 大半屏编辑卡片（参考聊天输入框展开模式）：4/5 屏底部弹层，
  /// 顶部标题 + 全屏大区域可滚动 TextField + 取消/保存。
  /// 关闭（返回/下滑/取消）不丢已输入内容（草稿留在 _draftCtrl）。
  /// 返回保存的文本（trim 后），取消返回 null。
  Future<String?> _openEditor({
    required String title,
    required String initial,
    required String hint,
  }) async {
    final theme = Theme.of(context);
    _draftCtrl.text = initial;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final targetHeight = mq.size.height * 0.8;
        final availableHeight =
            mq.size.height - mq.viewInsets.bottom - mq.padding.top - 12;
        final sheetHeight = availableHeight < targetHeight
            ? availableHeight
            : targetHeight;
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: Container(
              height: sheetHeight,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部：居中细把手 + 标题
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 正文：可滚动大编辑区（expands 占满、内部滚动）
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _draftCtrl,
                        autofocus: true,
                        expands: true,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(fontSize: 14, height: 1.6),
                        decoration: InputDecoration(
                          hintText: hint,
                          filled: true,
                          fillColor: context.fieldColor,
                          contentPadding: const EdgeInsets.all(14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 底部：取消 + 保存
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            onPressed: () =>
                                Navigator.pop(ctx, _draftCtrl.text.trim()),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(46),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text('保存'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 添加：弹大半屏编辑卡片，非空则追加并保存。
  Future<void> _add() async {
    final text = await _openEditor(
      title: '添加一件事',
      initial: _draftCtrl.text,
      hint: 'AI 助手想记住的事……',
    );
    if (text == null || text.isEmpty || !mounted) return;
    final saved = await _saveMemories([..._memories, text]);
    if (saved && mounted) _draftCtrl.clear();
  }

  /// 编辑：弹大半屏编辑卡片（预填当前内容），确认后更新该条并保存。
  Future<void> _edit(int index) async {
    final text = await _openEditor(
      title: '编辑这件事',
      initial: _memories[index],
      hint: 'AI 助手想记住的事……',
    );
    if (text == null || text.isEmpty || !mounted) return;
    if (text == _memories[index]) return;
    final saved = await _saveMemories([
      for (var i = 0; i < _memories.length; i++)
        if (i == index) text else _memories[i],
    ]);
    if (saved && mounted) _draftCtrl.clear();
  }

  /// 删除：确认后从列表移除并保存。
  Future<void> _remove(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这件事？'),
        content: Text(
          _memories[index],
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _saveMemories([
      for (var i = 0; i < _memories.length; i++)
        if (i != index) _memories[i],
    ]);
  }

  /// 保存记忆列表；返回是否保存成功。
  Future<bool> _saveMemories(List<String> next) async {
    if (_saving) return false;
    setState(() => _saving = true);
    final data = await SelfPromptApi.save(memories: next);
    if (!mounted) return false;
    setState(() {
      _saving = false;
      if (data != null) _memories = data.memories;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(data != null ? '已保存' : '保存失败，检查网络'),
          duration: const Duration(seconds: 2),
        ),
      );
    return data != null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('想记住的事'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _saving ? null : () => _load(force: true),
            icon: const Icon(LucideIcons.refresh_cw),
          ),
          IconButton(
            tooltip: '添加一件事',
            onPressed: _saving || _loading ? null : _add,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.plus),
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
            FilledButton(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_memories.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.sticky_note,
              size: 28,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有想记住的事',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              '点右上角 + 写下一件希望AI 助手记住的事',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (var i = 0; i < _memories.length; i++) ...[
          SettingCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.sticky_note,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${i + 1}. ${_memories[i]}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '编辑',
                  icon: Icon(
                    LucideIcons.pencil,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: _saving ? null : () => _edit(i),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: Icon(
                    LucideIcons.trash_2,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: _saving ? null : () => _remove(i),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '这里写下的内容会长期保留，帮助AI 助手在聊天时记得。',
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
