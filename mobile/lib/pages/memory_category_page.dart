import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/memory_card.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';

/// Continuum Chat 记忆分类页：主页分类入口卡的下一级。
/// 顶部分类名（像素 24 点缀）+ 返回钮 + 沉底筛选（全部/浮着/沉底），
/// 主体该分类主题卡两列网格（标题+摘要+新鲜度色点+沉底标签，基准简洁卡片），
/// 点卡弹详情弹层（完整正文+状态标识+年轮）。
/// 数据自己拉 /cards?include_sunk=true 再按分类过滤（主页只传分类名）。

class MemoryCategoryPage extends StatefulWidget {
  final String category;

  const MemoryCategoryPage({super.key, required this.category});

  @override
  State<MemoryCategoryPage> createState() => _MemoryCategoryPageState();
}

class _MemoryCategoryPageState extends State<MemoryCategoryPage> {
  List<MemoryCard> _all = const [];
  bool _loading = true;

  /// 筛选：all 全部 / fresh 浮着 / sunk 沉底
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显，过期/无缓存才静默拉新；
  /// 详情操作后 [force] 直接拉网。
  Future<void> _load({bool force = false}) async {
    final url = ServerConfig.url(8820, '/cards?include_sunk=true');
    if (!force && _all.isEmpty) {
      final cached = await ApiCache.read(url);
      final cachedAll = _parseCards(cached);
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
    final cards = _parseCards(raw);
    if (!mounted) return;
    setState(() {
      if (cards != null) _all = cards;
      _loading = false;
    });
  }

  static List<MemoryCard>? _parseCards(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) MemoryCard.fromJson(e),
    ];
  }

  List<MemoryCard> get _cards {
    // v0.2.151：新增 你/我/生活/心情/未分类 分类页。
    // 未分类 = tags 为空或主标签就是「未分类」；其余按主标签精确匹配；
    // 日期卡（日子）不进分类页，只在主页「最近日期」独立展示。
    final inCat = _all.where((c) {
      if (c.isDateCard) return false;
      final first = c.tags.split(',').first.trim();
      if (widget.category == '未分类') {
        return first.isEmpty || first == '未分类';
      }
      return first == widget.category;
    });
    final cards = switch (_filter) {
      'fresh' => inCat.where((c) => c.status == 'fresh').toList(),
      'sunk' => inCat.where((c) => c.status == 'sunk').toList(),
      _ => inCat.toList(),
    };
    cards.sort((a, b) {
      final pinned = b.pinned.compareTo(a.pinned);
      if (pinned != 0) return pinned;
      final status = _statusRank(a.status).compareTo(_statusRank(b.status));
      if (status != 0) return status;
      return b.createdAt.compareTo(a.createdAt);
    });
    return cards;
  }

  int _statusRank(String status) => status == 'fresh' ? 0 : 1;

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
                      widget.category,
                      style: memPx(24, memAccentOf(context), height: 1.2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _filterRow(),
              const SizedBox(height: 8),
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
                    : _cards.isEmpty
                    ? _empty()
                    : _grid(context),
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

  /// 沉底筛选：全部 / 浮着 / 沉底（胶囊分段）。
  Widget _filterRow() {
    final memT = memTextOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          for (final (key, label) in const [
            ('all', '全部'),
            ('fresh', '浮着'),
            ('sunk', '沉底'),
          ]) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _filter = key),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _filter == key
                      ? memAccentOf(context).withValues(alpha: 0.14)
                      : context.fieldColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: memBody(
                    13,
                    _filter == key
                        ? memAccentOf(context)
                        : memT.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  /// 分类下主题卡两列网格：标题 + 摘要 + 新鲜度色点 + 沉底标签。
  Widget _grid(BuildContext context) {
    final memT = memTextOf(context);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 132,
      ),
      itemCount: _cards.length,
      itemBuilder: (context, i) {
        final card = _cards[i];
        return GestureDetector(
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
                    FreshnessDot(freshness: card.freshness),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    card.content.isEmpty ? '（空）' : card.content,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: memBody(13, memT.withValues(alpha: 0.6)),
                  ),
                ),
                if (card.status == 'sunk') ...[
                  const SizedBox(height: 6),
                  Text('已沉底', style: memBody(12, memT.withValues(alpha: 0.35))),
                ],
              ],
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
      child: Text('这里还没有记忆', style: memPx(24, memT.withValues(alpha: 0.35))),
    );
  }

  /// 卡片详情弹层（主页同款：完整正文 + 状态标识 + 年轮）。
  /// 关闭后刷新：归档操作后卡片离开活跃区。
  Future<void> _openDetail(BuildContext context, MemoryCard card) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryDetailSheet(card: card),
    );
    if (!mounted) return;
    _load(force: true);
  }
}
