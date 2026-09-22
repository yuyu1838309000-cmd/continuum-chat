import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/pixel_home.dart';
import '../utils/app_theme.dart';

/// 可点物品：key -> (中文名, emoji)。弹窗内容读 stocks/bed。
const Map<String, (String, String)> _itemMeta = {
  'fridge': ('冰箱', '🧊'),
  'cabinet': ('橱柜', '🍶'),
  'teaTable': ('茶几', '🍵'),
  'pantry': ('囤货柜', '🥫'),
  'bed': ('床', '🛏️'),
};

/// 房间里的可点物品（第一版骨架的固定摆放）。
const Map<String, List<String>> _roomItems = {
  'kitchen': ['fridge', 'cabinet'],
  'bedroom': ['bed'],
  'living': ['teaTable'],
  'storage': ['pantry'],
};

/// 房间详情（小家 v0.2.155）：房间 zones 列表 + 房间痕迹 +
/// 可点物品（fridge/bed/teaTable/cabinet/pantry），点了弹窗显示内容。
/// 数据由 PixelHomePage 拉好后传入，本页不再请求网络。
class PixelRoomPage extends StatelessWidget {
  final String roomId;
  final String roomName;
  final PixelHome home;

  const PixelRoomPage({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.home,
  });

  @override
  Widget build(BuildContext context) {
    final room = home.rooms[roomId];
    final zones = room?.zones ?? const <HomeZone>[];
    final traces = home.roomTraces[roomId] ?? const <String>[];
    final items = _roomItems[roomId] ?? const <String>[];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: Text(roomName),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _zonesCard(context, zones),
            if (traces.isNotEmpty) _tracesCard(context, traces),
            for (final itemId in items) _itemCard(context, itemId),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── zones 列表 ──
  Widget _zonesCard(BuildContext context, List<HomeZone> zones) {
    final occupants = _occupantsLine();
    return _card(
      context,
      child: zones.isEmpty
          ? Text(
              '这间房还没摆东西',
              style: TextStyle(fontSize: 13, color: context.subTextColor),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (occupants.isNotEmpty) ...[
                  Text(
                    occupants,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: context.subTextColor,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                for (var i = 0; i < zones.length; i++) ...[
                  if (i > 0) const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (zones[i].icon.isNotEmpty) ...[
                        Text(
                          zones[i].icon,
                          style: const TextStyle(fontSize: 18),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              zones[i].name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (zones[i].desc.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                zones[i].desc,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.5,
                                  color: context.subTextColor,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  // ── 房间痕迹 ──
  Widget _tracesCard(BuildContext context, List<String> traces) {
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < traces.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.sparkles,
                    size: 14,
                    color: context.subTextColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      traces[i],
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: context.subTextColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── 可点物品 ──
  Widget _itemCard(BuildContext context, String itemId) {
    final (name, emoji) = _itemMeta[itemId]!;
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
          onTap: () => _showItemDialog(context, itemId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 24)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  LucideIcons.chevron_right,
                  size: 22,
                  color: context.subTextColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) {
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
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    );
  }

  /// 谁在这间房：名字 + 动作，一行小字。
  String _occupantsLine() {
    final parts = <String>[
      if (home.me.room == roomId && home.me.action.isNotEmpty)
        'AI 助手 · ${home.me.action}',
      if (home.appUser.room == roomId && home.appUser.action.isNotEmpty)
        '用户 · ${home.appUser.action}',
      if (home.cat.room == roomId && home.cat.action.isNotEmpty)
        '猫咪 · ${home.cat.action}',
    ];
    return parts.join('　');
  }

  // ── 物品弹窗 ──
  void _showItemDialog(BuildContext context, String itemId) {
    final (name, emoji) = _itemMeta[itemId]!;
    final zone = home.stocks[itemId];
    final content = itemId == 'bed'
        ? _bedContent(context, home.bed)
        : _stockContent(context, zone);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Text(name),
          ],
        ),
        content: SingleChildScrollView(child: content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  Widget _stockContent(BuildContext context, StockZone? zone) {
    final items = zone?.items ?? const <StockItem>[];
    final note = zone?.note ?? '';
    if (items.isEmpty) {
      return Text(
        '空空的，还没放东西',
        style: TextStyle(fontSize: 13, color: context.subTextColor),
      );
    }
    // 第一版骨架防超长：冰箱等区可能攒了上万条历史批次，弹窗最多列 40 行。
    const maxRows = 40;
    final shown = items.length > maxRows ? items.take(maxRows) : items;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                if (item.emoji.isNotEmpty) ...[
                  Text(item.emoji, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(item.name, style: const TextStyle(fontSize: 14)),
                ),
                Text(
                  '×${item.qtyLabel}',
                  style: TextStyle(fontSize: 12, color: context.subTextColor),
                ),
              ],
            ),
          ),
        if (items.length > maxRows) ...[
          const SizedBox(height: 6),
          Text(
            '…还有 ${items.length - maxRows} 件',
            style: TextStyle(fontSize: 12, color: context.subTextColor),
          ),
        ],
        if (note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            note,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: context.subTextColor,
            ),
          ),
        ],
      ],
    );
  }

  Widget _bedContent(BuildContext context, BedState bed) {
    final rows = <(String, String)>[
      ('铺好了', bed.made ? '是' : '还没'),
      if (bed.pillows.isNotEmpty) ('枕头', bed.pillows.join('、')),
      if (bed.lastSlept.isNotEmpty) ('最近睡过', bed.lastSlept),
      if (bed.extras.isNotEmpty) ('床上还有', bed.extras.join('、')),
      if (bed.note.isNotEmpty) ('备注', bed.note),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 12, color: context.subTextColor),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
