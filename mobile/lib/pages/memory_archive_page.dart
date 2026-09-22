import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/memory_card.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';

/// Continuum Chat 归档页：手动归档的记忆（不参与自动注入）。
/// 顶部分类名（像素 24 点缀）+ 返回钮 + 条数，主体归档卡列表
/// （标题 + 内容摘要 + 年轮数，基准简洁卡片），点卡弹详情（可取消归档）。

class MemoryArchivePage extends StatefulWidget {
  const MemoryArchivePage({super.key});

  @override
  State<MemoryArchivePage> createState() => _MemoryArchivePageState();
}

class _MemoryArchivePageState extends State<MemoryArchivePage> {
  List<MemoryDetail> _all = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显，过期/无缓存才静默拉新；
  /// 详情操作后 [force] 直接拉网。
  Future<void> _load({bool force = false}) async {
    final url = ServerConfig.url(8820, '/archive');
    if (!force && _all.isEmpty) {
      final cached = await ApiCache.read(url);
      final cachedAll = _parseArchive(cached);
      if (!mounted) return;
      if (cachedAll != null) {
        setState(() {
          _all = cachedAll;
          _loading = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    final raw = await ApiCache.fetchJson(
      url,
      timeout: const Duration(seconds: 8),
    );
    final items = _parseArchive(raw);
    if (!mounted) return;
    setState(() {
      if (items != null) _all = items;
      _loading = false;
    });
  }

  static List<MemoryDetail>? _parseArchive(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>)
          MemoryDetail(
            card: MemoryCard.fromJson(e),
            rings: [
              for (final r in (e['rings'] as List<dynamic>? ?? const []))
                if (r is Map<String, dynamic>) MemoryRing.fromJson(r),
            ],
            reproducible: e['reproducible'] == true,
          ),
    ];
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
                      '归档',
                      style: memPx(24, memAccentOf(context), height: 1.2),
                    ),
                    const Spacer(),
                    if (!_loading)
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
              Expanded(
                child: _loading
                    ? Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            color: memAccentOf(context),
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    : _all.isEmpty
                    ? _empty()
                    : _list(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 返回小圆钮（与主页一致，无文字）。
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

  /// 归档卡列表：标题 + 内容摘要 + 年轮数（整条可点弹详情）。
  Widget _list(BuildContext context) {
    final memT = memTextOf(context);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
      itemCount: _all.length,
      itemBuilder: (context, i) {
        final detail = _all[i];
        final card = detail.card;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openDetail(context, card),
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 空态。
  Widget _empty() {
    final memT = memTextOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.archive,
            size: 24,
            color: memT.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text('还没有归档的记忆', style: memPx(24, memT.withValues(alpha: 0.35))),
        ],
      ),
    );
  }

  /// 卡片详情弹层（isArchived=true：带「取消归档」按钮）。
  /// 关闭后刷新：取消归档后卡片移回活跃区。
  Future<void> _openDetail(BuildContext context, MemoryCard card) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryDetailSheet(card: card, isArchived: true),
    );
    if (!mounted) return;
    _load(force: true);
  }
}
