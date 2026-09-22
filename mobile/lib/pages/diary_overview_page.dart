import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/personal_space.dart';
import '../utils/app_theme.dart';
import '../utils/diary_mood.dart';
import 'diary_detail_page.dart';

/// 日记日期总览：保持日历业务，有日记的日期沿用真实心情状态色。
class DiaryOverviewPage extends StatefulWidget {
  final List<DiaryEntry> entries;

  const DiaryOverviewPage({super.key, required this.entries});

  @override
  State<DiaryOverviewPage> createState() => _DiaryOverviewPageState();
}

class _DiaryOverviewPageState extends State<DiaryOverviewPage> {
  late final List<DiaryEntry> _sorted;
  late final Map<String, DiaryEntry> _entryByDate;

  @override
  void initState() {
    super.initState();
    _sorted = List.of(widget.entries)..sort((a, b) => a.date.compareTo(b.date));
    _entryByDate = {for (final e in _sorted) _normalizeDate(e.date): e};
  }

  /// 把后端可能不补零的日期统一成 yyyy-MM-dd，保证日期格子匹配稳定。
  String _normalizeDate(String date) {
    final parts = date.split('-');
    if (parts.length != 3) return date;
    final y = parts[0].padLeft(4, '0');
    final m = parts[1].padLeft(2, '0');
    final d = parts[2].padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('日期总览'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: _sorted.isEmpty
            ? Center(
                child: Text(
                  '还没有日记',
                  style: TextStyle(fontSize: 13, color: context.subTextColor),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xl,
                ),
                children: [
                  _buildLegend(context),
                  const SizedBox(height: AppSpacing.lg),
                  for (final month in _months(_sorted)) ...[
                    _buildMonth(context, month),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        for (final item in diaryMoodLegend)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: item.color,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox(width: 8, height: 8),
              ),
              const SizedBox(width: 6),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: AppType.timestamp,
                  color: context.subTextColor.withValues(alpha: 0.72),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildMonth(BuildContext context, String month) {
    final parts = month.split('-');
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final mon = int.tryParse(parts[1]) ?? DateTime.now().month;
    final first = DateTime(year, mon, 1);
    final days = DateTime(year, mon + 1, 0).day;
    final leading = first.weekday - 1; // 周一作为第一列
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
          child: Text(
            '$year年$mon月',
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _weekdayHeader(context),
        const SizedBox(height: AppSpacing.xs),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1,
          children: [
            for (var i = 0; i < leading; i++) const SizedBox.shrink(),
            for (var d = 1; d <= days; d++) _buildDay(context, year, mon, d),
          ],
        ),
      ],
    );
  }

  Widget _weekdayHeader(BuildContext context) {
    return Row(
      children: [
        for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
          Expanded(
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppType.timestamp,
                  color: context.subTextColor.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDay(BuildContext context, int year, int month, int day) {
    final date =
        '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
    final entry = _entryByDate[_normalizeDate(date)];
    if (entry == null) {
      return Center(
        child: Text(
          '$day',
          style: TextStyle(
            fontSize: 12,
            color: context.subTextColor.withValues(alpha: 0.28),
          ),
        ),
      );
    }
    final color = diaryMoodColor(entry.moodScore);
    final textColor = diaryMoodTextColor(entry.moodScore);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openEntry(entry),
        child: Center(
          child: Text(
            '$day',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  void _openEntry(DiaryEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DiaryDetailPage(entry: entry)),
    );
  }

  List<String> _months(List<DiaryEntry> entries) {
    final months = <String>[];
    for (final e in entries) {
      if (e.date.length < 7) continue;
      final m = e.date.substring(0, 7);
      if (!months.contains(m)) months.add(m);
    }
    return months;
  }
}
