import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/memory_card.dart';
import '../services/memory_api.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';

/// Continuum Chat 回收站：软删的记忆卡，可恢复或彻底删除。
class MemoryTrashPage extends StatefulWidget {
  const MemoryTrashPage({super.key});

  @override
  State<MemoryTrashPage> createState() => _MemoryTrashPageState();
}

class _MemoryTrashPageState extends State<MemoryTrashPage> {
  List<MemoryDetail> _all = const [];
  bool _loading = true;
  bool _failed = false;
  int? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final items = await MemoryApi.listTrash();
    if (!mounted) return;
    setState(() {
      if (items == null) {
        _failed = true;
      } else {
        _all = items;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    _backButton(context),
                    const SizedBox(width: 12),
                    Text(
                      '回收站',
                      style: memPx(24, memAccentOf(context), height: 1.2),
                    ),
                    const Spacer(),
                    if (!_loading && !_failed)
                      Text(
                        '${_all.length} 条',
                        style: memBody(
                          12,
                          memTextOf(context).withValues(alpha: 0.45),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            color: memAccentOf(context),
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_failed) return _error();
    if (_all.isEmpty) return _empty();
    return _list(context);
  }

  Widget _backButton(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: memCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.all(10),
        child: Icon(
          LucideIcons.arrow_left,
          size: 20,
          color: memTextOf(context),
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final memT = memTextOf(context);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
      itemCount: _all.length,
      itemBuilder: (context, i) {
        final detail = _all[i];
        final card = detail.card;
        final busy = _busyId == card.id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: memCard(
            context: context,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        card.title.isEmpty ? '未命名' : card.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: memPx(12, memT, height: 1.4),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${detail.rings.length} 圈年轮',
                      style: memPx(12, memT.withValues(alpha: 0.35)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  card.content.isEmpty ? '（空）' : card.content,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: memBody(13, memT.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _pillButton(
                      icon: LucideIcons.archive_restore,
                      label: '恢复',
                      color: context.accentColor,
                      onTap: busy ? null : () => _restore(card),
                    ),
                    _pillButton(
                      icon: LucideIcons.trash_2,
                      label: '彻底删除',
                      color: Theme.of(context).colorScheme.error,
                      onTap: busy ? null : () => _confirmPurge(card),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pillButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.fieldColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 7),
                Text(label, style: memBody(13, color, height: 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() {
    final memT = memTextOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.trash_2,
            size: 24,
            color: memT.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text('回收站是空的', style: memPx(24, memT.withValues(alpha: 0.35))),
        ],
      ),
    );
  }

  Widget _error() {
    final memT = memTextOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.wifi_off,
            size: 24,
            color: memT.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text('记忆库连不上', style: memBody(14, memT.withValues(alpha: 0.7))),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _load,
            child: memCard(
              context: context,
              radius: 999,
              fullWidth: false,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              child: Text('重试', style: memBody(13, memT)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(MemoryCard card) async {
    setState(() => _busyId = card.id);
    final ok = await MemoryApi.trashCard(card.id, action: 'restore');
    if (!mounted) return;
    setState(() {
      _busyId = null;
      if (ok) _all = _all.where((d) => d.card.id != card.id).toList();
    });
    _toast(ok ? '已恢复' : '恢复失败');
  }

  Future<void> _confirmPurge(MemoryCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除记忆'),
        content: const Text('这条记忆和它的年轮会从服务器删除，删除后不能恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyId = card.id);
    final ok = await MemoryApi.trashCard(card.id, action: 'purge');
    if (!mounted) return;
    setState(() {
      _busyId = null;
      if (ok) _all = _all.where((d) => d.card.id != card.id).toList();
    });
    _toast(ok ? '已彻底删除' : '彻底删除失败');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }
}
