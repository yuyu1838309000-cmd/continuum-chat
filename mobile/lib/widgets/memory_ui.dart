import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/memory_card.dart';
import '../models/mood.dart';
import '../services/memory_api.dart';
import '../utils/app_theme.dart';

/// 记忆面板共用视觉（主页 / 分类页 / 日期页 / 详情弹层）。
/// 基准简洁卡片风（v0.2.92）：背景跟主题（context.bgColor）、卡片统一
/// 圆角 20 + 柔和阴影 + cardColor 底、点缀色只走主题主色（memAccentOf）、
/// 标题/数字/日期用 memPx、正文 memBody，字体族一律走系统无衬线。
/// 粉蓝渐变 + 磨砂玻璃（旧版）已废弃，不许再引入。

/// 记忆面板点缀色：主题主色（金色/暖橙/薄荷/薰衣草随主题）。
Color memAccentOf(BuildContext context) =>
    Theme.of(context).colorScheme.primary;

/// 记忆面板主文字色：主题语义（浅色深字 / 深色浅字）。
Color memTextOf(BuildContext context) => context.textColor;

/// 记忆面板基准卡片：圆角 20 + 柔和阴影 + cardColor 底（config 卡片同款）。
/// [radius] 默认 20，圆钮传 999；[padding] 默认 20 四周。
Widget memCard({
  required BuildContext context,
  required Widget child,
  double radius = 20,
  EdgeInsetsGeometry? padding,
  bool fullWidth = true,
}) {
  return Container(
    width: fullWidth ? double.infinity : null,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [context.cardShadow],
    ),
    child: Material(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(20),
        child: child,
      ),
    ),
  );
}

/// 标题/数字/日期样式：系统无衬线（内置像素字体已移除，字号不再按点阵换算）。
TextStyle memPx(double size, Color color, {double? height}) =>
    TextStyle(fontSize: size, color: color, height: height);

/// 正文样式：系统无衬线，大段内容可读。
TextStyle memBody(double size, Color color, {double? height}) =>
    TextStyle(fontSize: size, color: color, height: height ?? 1.6);

/// 干净卡片（情绪相关页面）：基准卡片同款（cardColor + 柔和阴影 + 圆角），
/// 圆形按钮场景传 [circle]（返回钮用）。
Widget memCleanCard({
  required BuildContext context,
  required Widget child,
  double radius = 20,
  EdgeInsetsGeometry? padding = const EdgeInsets.all(24),
  bool circle = false,
  bool fullWidth = true,
}) {
  return Container(
    width: fullWidth ? double.infinity : null,
    padding: circle ? null : padding,
    decoration: BoxDecoration(
      color: context.cardColor,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
      boxShadow: [context.cardShadow],
    ),
    child: child,
  );
}

/// 完整时间：今天/昨天 → "今天 00:25"，更早 → "08-05 22:10"。
String memTimeFull(String raw) {
  final t = DateTime.tryParse(raw);
  if (t == null) return raw;
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天 $hm';
  if (diff == 1) return '昨天 $hm';
  return '${two(t.month)}-${two(t.day)} $hm';
}

/// 短时间：今天 → "00:25"，更早 → "08-05 22:10"。
String memTimeShort(String raw) {
  final t = DateTime.tryParse(raw);
  if (t == null) return raw;
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (today.difference(day).inDays == 0) return hm;
  return '${two(t.month)}-${two(t.day)} $hm';
}

/// 情绪行：emoji + 标签 + 分值 + 时间（情绪仪表盘/记忆页情绪区块共用）。
class MoodRow extends StatelessWidget {
  final MoodEntry mood;
  final bool showNote;
  final bool fullTime;

  const MoodRow({
    super.key,
    required this.mood,
    this.showNote = false,
    this.fullTime = false,
  });

  @override
  Widget build(BuildContext context) {
    final memT = memTextOf(context);
    final grey = memT.withValues(alpha: 0.5);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          mood.emoji.isEmpty ? '😶' : mood.emoji,
          style: const TextStyle(fontSize: 18, height: 1),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mood.label.isEmpty ? '未知' : mood.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: memBody(14, memT, height: 1),
              ),
              if (showNote && mood.note.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  mood.note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: memBody(12, grey, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        Text(
          mood.valence > 0 ? '+${mood.valence}' : '${mood.valence}',
          style: memPx(12, memT.withValues(alpha: 0.85), height: 1),
        ),
        const SizedBox(width: 14),
        Text(
          fullTime ? memTimeFull(mood.createdAt) : memTimeShort(mood.createdAt),
          style: memBody(11, grey, height: 1),
        ),
      ],
    );
  }
}

/// 新鲜度色点（主题语义）：热=主色 / 温=tertiary / 冷=outline，未知灰。
Color memFreshnessColor(BuildContext context, String freshness) =>
    switch (freshness) {
      'fresh' => Theme.of(context).colorScheme.primary,
      'warm' => Theme.of(context).colorScheme.tertiary,
      _ => Theme.of(context).colorScheme.outline,
    };

/// 新鲜度中文：热/温/冷。
String memFreshnessLabel(String freshness) => switch (freshness) {
  'fresh' => '热',
  'warm' => '温',
  'cold' => '冷',
  _ => '',
};

/// 新鲜度小圆点（卡片右上角状态标识）。
class FreshnessDot extends StatelessWidget {
  final String freshness;
  final double size;

  const FreshnessDot({super.key, required this.freshness, this.size = 8});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: memFreshnessColor(context, freshness),
      ),
    );
  }
}

/// 卡片详情弹层：完整正文 + 状态标识（新鲜度/可复现/已归档）+ 年轮列表（/card/{id}）。
/// [isArchived] 为 true 时（归档区打开）显示「取消归档」按钮，否则显示「归档」按钮。
/// 删除是软删进回收站，卡片 id 和年轮保留。
class MemoryDetailSheet extends StatefulWidget {
  final MemoryCard card;
  final bool isArchived;

  const MemoryDetailSheet({
    super.key,
    required this.card,
    this.isArchived = false,
  });

  @override
  State<MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<MemoryDetailSheet> {
  MemoryCard? _full;
  List<MemoryRing> _rings = const [];
  List<String> _keywords = const [];
  bool _reproducible = false;

  /// 是否处于归档状态（详情拉回的最新 status 优先，兜底用传入参数）。
  bool get _archived =>
      (_full?.status ?? widget.card.status) == 'archived' || widget.isArchived;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final detail = await MemoryApi.detail(widget.card.id);
    if (!mounted || detail == null) return;
    setState(() {
      _full = detail.card;
      _rings = detail.rings;
      _keywords = _splitKeywords(detail.card.keywords);
      _reproducible = detail.reproducible;
    });
  }

  List<String> _splitKeywords(String raw) => [
    for (final k in raw.split(','))
      if (k.trim().isNotEmpty) k.trim(),
  ];

  @override
  Widget build(BuildContext context) {
    final card = _full ?? widget.card;
    final title = card.title.isEmpty ? null : card.title;
    final freshness = (_full ?? widget.card).freshness;
    final memT = memTextOf(context);
    final bottomPad =
        MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom +
        24;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPad),
      child: FractionallySizedBox(
        heightFactor: 0.82,
        child: memCard(
          context: context,
          radius: 24,
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (title != null) ...[
                      Text(title, style: memPx(24, memT, height: 1.3)),
                      const SizedBox(height: 16),
                    ],
                    _statusRow(freshness),
                    const SizedBox(height: 20),
                    Text(
                      card.content.isEmpty ? '（空）' : card.content,
                      style: memBody(14, memT.withValues(alpha: 0.85)),
                    ),
                    if (_rings.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      Text('年轮', style: memPx(12, memT.withValues(alpha: 0.4))),
                      const SizedBox(height: 8),
                      for (final ring in _rings) _ringRow(ring),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 24),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [_editButton(), _archiveButton(), _deleteButton()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 归档 / 取消归档按钮：活跃区显示「归档」，归档区显示「取消归档」。
  Widget _archiveButton() {
    final unarchive = _archived;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggleArchive(unarchive),
      child: memCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              unarchive ? LucideIcons.archive_restore : LucideIcons.archive,
              size: 15,
              color: context.accentColor,
            ),
            const SizedBox(width: 8),
            Text(
              unarchive ? '取消归档' : '归档',
              style: memBody(13, context.accentColor),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleArchive(bool unarchive) async {
    final ok = await MemoryApi.archiveCard(
      widget.card.id,
      unarchive: unarchive,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(unarchive ? '取消归档失败' : '归档失败'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 删除按钮：软删进回收站，可在回收站恢复。
  Widget _deleteButton() {
    final error = Theme.of(context).colorScheme.error;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _trash,
      child: memCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.trash_2, size: 15, color: error),
            const SizedBox(width: 8),
            Text('删除', style: memBody(13, error)),
          ],
        ),
      ),
    );
  }

  Future<void> _trash() async {
    final ok = await MemoryApi.trashCard(widget.card.id, action: 'trash');
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败'), duration: Duration(seconds: 2)),
      );
    }
  }

  /// 【标签】入口：弹关键词编辑弹层，关闭后重拉详情刷新展示。
  Future<void> _openKeywords() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryKeywordsSheet(
        cardId: widget.card.id,
        initialKeywords: _keywords,
      ),
    );
    if (mounted) _load();
  }

  /// 编辑按钮（胶囊）：弹编辑弹窗改标题/正文 → POST /update → 重拉详情。
  Widget _editButton() {
    final memT = memTextOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _edit,
      child: memCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.pencil,
              size: 15,
              color: memT.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 8),
            Text('编辑', style: memBody(13, memT.withValues(alpha: 0.9))),
          ],
        ),
      ),
    );
  }

  Future<void> _edit() async {
    final card = _full ?? widget.card;
    final result = await showModalBottomSheet<MemoryEditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryEditSheet(
        titleLabel: '编辑记忆',
        confirmLabel: '保存',
        initialTitle: card.title.isEmpty ? '' : card.title,
        initialContent: card.content,
        onSave: (title, content) async {
          final expectedRevisionId = card.currentRevisionId;
          if (expectedRevisionId == null) {
            return const MemoryEditResult(
              saved: false,
              message: '记忆信息未加载，请刷新后重试',
            );
          }
          final result = await MemoryApi.updateCard(
            card.id,
            expectedCurrentRevisionId: expectedRevisionId,
            title: title,
            content: content,
          );
          if (result.conflict) {
            return const MemoryEditResult(
              saved: false,
              message: '记忆已变化，请刷新后重试',
            );
          }
          if (result.card == null) {
            return const MemoryEditResult(saved: false, message: '保存失败');
          }
          return const MemoryEditResult(saved: true, message: '已保存');
        },
      ),
    );
    if (result?.saved == true && mounted) {
      _load(); // 重拉详情：正文/年轮展示最新
    }
  }

  /// 状态标识行：新鲜度（色点+文字）+ 可复现（图标+文字）。
  Widget _statusRow(String freshness) {
    final memT = memTextOf(context);
    final label = memFreshnessLabel(freshness);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (label.isNotEmpty)
          _badge(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FreshnessDot(freshness: freshness),
                const SizedBox(width: 6),
                Text(
                  '记忆$label',
                  style: memBody(12, memT.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        if (_reproducible)
          _badge(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.history,
                  size: 13,
                  color: memT.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 5),
                Text('可复现', style: memBody(12, memT.withValues(alpha: 0.6))),
              ],
            ),
          ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openKeywords,
          child: _badge(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.tag,
                  size: 13,
                  color: memT.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 5),
                Text(
                  _keywords.isEmpty ? '标签' : '标签 ${_keywords.length}',
                  style: memBody(12, memT.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ),
        if (_archived)
          _badge(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.archive,
                  size: 13,
                  color: memT.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 5),
                Text('已归档', style: memBody(12, memT.withValues(alpha: 0.6))),
              ],
            ),
          ),
      ],
    );
  }

  Widget _badge({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: child,
    );
  }

  Widget _ringRow(MemoryRing ring) {
    final memT = memTextOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: memAccentOf(context),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ring.content.isEmpty ? '（空）' : ring.content,
                  style: memBody(13, memT.withValues(alpha: 0.8)),
                ),
                if (ring.createdAt.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    ring.createdAt,
                    style: memPx(12, memT.withValues(alpha: 0.35)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 同一天多张卡时：先列当天卡片，再点开单卡详情（主页近两天卡 / 日期页共用）。
class MemoryDaySheet extends StatelessWidget {
  final String day;
  final List<MemoryCard> cards;
  final void Function(MemoryCard card) onOpenCard;

  const MemoryDaySheet({
    super.key,
    required this.day,
    required this.cards,
    required this.onOpenCard,
  });

  @override
  Widget build(BuildContext context) {
    final memT = memTextOf(context);
    final bottomPad =
        MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom +
        24;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPad),
      child: FractionallySizedBox(
        heightFactor: 0.72,
        child: memCard(
          context: context,
          radius: 24,
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '$day · ${cards.length} 条',
                style: memPx(24, memT, height: 1.3),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final card in cards)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            Navigator.of(context).pop();
                            onOpenCard(card);
                          },
                          child: memCard(
                            context: context,
                            radius: 16,
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (card.title.isNotEmpty) ...[
                                  Text(
                                    card.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: memPx(12, memT, height: 1.4),
                                  ),
                                  const SizedBox(height: 6),
                                ],
                                Text(
                                  card.content.isEmpty ? '（空）' : card.content,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: memBody(
                                    13,
                                    memT.withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
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
  }
}

/// 关键词编辑弹层：chip 列表 + 添加输入框，增删走 POST /keywords 并实时刷新。
class MemoryKeywordsSheet extends StatefulWidget {
  final int cardId;
  final List<String> initialKeywords;

  const MemoryKeywordsSheet({
    super.key,
    required this.cardId,
    required this.initialKeywords,
  });

  @override
  State<MemoryKeywordsSheet> createState() => _MemoryKeywordsSheetState();
}

class _MemoryKeywordsSheetState extends State<MemoryKeywordsSheet> {
  late List<String> _keywords;
  final TextEditingController _input = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _keywords = List.of(widget.initialKeywords);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final kw = _input.text.trim();
    if (kw.isEmpty || _busy) return;
    setState(() => _busy = true);
    final updated = await MemoryApi.updateKeywords(
      widget.cardId,
      action: 'add',
      keyword: kw,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) {
        _keywords = updated;
        _input.clear();
      }
    });
    if (updated == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('添加失败'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _remove(String kw) async {
    if (_busy) return;
    setState(() => _busy = true);
    final updated = await MemoryApi.updateKeywords(
      widget.cardId,
      action: 'remove',
      keyword: kw,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) _keywords = updated;
    });
    if (updated == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final memT = memTextOf(context);
    final bottomPad =
        MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom +
        24;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPad),
      child: memCard(
        context: context,
        radius: 24,
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('标签', style: memPx(24, memT, height: 1.3)),
            const SizedBox(height: 16),
            if (_keywords.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '还没有关键词，添加一个吧',
                  style: memBody(12, memT.withValues(alpha: 0.4)),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final kw in _keywords) _chip(kw)],
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: memBody(14, memT),
                    onSubmitted: (_) => _add(),
                    decoration: InputDecoration(
                      hintText: '添加关键词…',
                      hintStyle: memBody(13, memT.withValues(alpha: 0.35)),
                      filled: true,
                      fillColor: context.fieldColor,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: context.accentColor,
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _busy ? null : _add,
                  child: memCard(
                    context: context,
                    radius: 999,
                    fullWidth: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 11,
                    ),
                    child: _busy
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              color: context.accentColor,
                              strokeWidth: 2,
                            ),
                          )
                        : Text('添加', style: memBody(13, context.accentColor)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _chip(String kw) {
    final memT = memTextOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(kw, style: memBody(12, memT.withValues(alpha: 0.75))),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _busy ? null : () => _remove(kw),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                LucideIcons.x,
                size: 12,
                color: memT.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 记忆编辑弹窗结果：saved=true 已保存（带提示文案），false=失败（弹窗内显示 error 留在原地）。
class MemoryEditResult {
  final bool saved;
  final String message;

  const MemoryEditResult({required this.saved, required this.message});
}

/// 新增 / 编辑记忆共用弹窗（磨砂玻璃底部弹层）。
/// [onSave] 返回 MemoryEditResult：saved=true 保存成功并关闭弹窗；false 在弹窗内显示 message。
class MemoryEditSheet extends StatefulWidget {
  final String titleLabel;
  final String confirmLabel;
  final String initialTitle;
  final String initialContent;
  final Future<MemoryEditResult> Function(String title, String content) onSave;

  const MemoryEditSheet({
    super.key,
    required this.titleLabel,
    required this.confirmLabel,
    this.initialTitle = '',
    this.initialContent = '',
    required this.onSave,
  });

  @override
  State<MemoryEditSheet> createState() => _MemoryEditSheetState();
}

class _MemoryEditSheetState extends State<MemoryEditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _content = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    final content = _content.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '内容不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.onSave(title, content);
    if (!mounted) return;
    if (result.saved) {
      Navigator.of(context).pop(result);
    } else {
      setState(() {
        _saving = false;
        _error = result.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final memT = memTextOf(context);
    final media = MediaQuery.of(context);
    final keyboardInset = media.viewInsets.bottom;
    final maxSheetHeight =
        (media.size.height - keyboardInset - media.padding.bottom - 16)
            .clamp(220.0, media.size.height * 0.92)
            .toDouble();
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            child: memCard(
              context: context,
              radius: 24,
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(widget.titleLabel, style: memPx(24, memT, height: 1.3)),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _field(
                            controller: _title,
                            hint: '标题（可空）',
                            maxLines: 1,
                          ),
                          const SizedBox(height: 12),
                          _field(
                            controller: _content,
                            hint: '写下这条记忆…',
                            maxLines: 5,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              style: memBody(12, context.dangerColor),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _saving ? null : _save,
                      child: memCard(
                        context: context,
                        radius: 999,
                        fullWidth: false,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 12,
                        ),
                        child: _saving
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: context.accentColor,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                widget.confirmLabel,
                                style: memBody(13, context.accentColor),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required int maxLines,
  }) {
    final memT = memTextOf(context);
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: memBody(14, memT),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: memBody(13, memT.withValues(alpha: 0.35)),
        filled: true,
        fillColor: context.fieldColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: context.accentColor, width: 1),
        ),
      ),
    );
  }
}
