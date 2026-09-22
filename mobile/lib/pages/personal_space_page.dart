import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/personal_space.dart';
import '../services/contemplation_api.dart';
import '../services/personal_space_api.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart' show memTimeFull;
import '../widgets/swipe_back.dart';
import 'contemplation_page.dart';
import 'diary_list_page.dart';
import 'whisper_list_page.dart';

typedef DiarySummaryLoader =
    Future<List<DiaryEntry>?> Function({
      void Function(List<DiaryEntry> entries)? onCached,
    });
typedef WhisperSummaryLoader =
    Future<List<Whisper>?> Function({
      void Function(List<Whisper> entries)? onCached,
    });
typedef ContemplationCountLoader =
    Future<int?> Function({void Function(int count)? onCached});

/// 个人内容摘要页。三项数据独立加载，单项失败不影响其余内容。
class PersonalSpacePage extends StatefulWidget {
  const PersonalSpacePage({
    super.key,
    this.diaryLoader = PersonalSpaceApi.diary,
    this.whisperLoader = PersonalSpaceApi.whisper,
    this.contemplationCountLoader = ContemplationApi.count,
  });

  final DiarySummaryLoader diaryLoader;
  final WhisperSummaryLoader whisperLoader;
  final ContemplationCountLoader contemplationCountLoader;

  @override
  State<PersonalSpacePage> createState() => _PersonalSpacePageState();
}

class _PersonalSpacePageState extends State<PersonalSpacePage> {
  List<DiaryEntry>? _diaries;
  List<Whisper>? _whispers;
  int? _contemplationCount;
  bool _diaryLoading = true;
  bool _whisperLoading = true;
  bool _contemplationLoading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDiary());
    unawaited(_loadWhispers());
    unawaited(_loadContemplationCount());
  }

  Future<void> _loadDiary() async {
    final entries = await widget.diaryLoader(onCached: _showCachedDiary);
    if (!mounted) return;
    setState(() {
      _diaries = entries;
      _diaryLoading = false;
    });
  }

  void _showCachedDiary(List<DiaryEntry> entries) {
    if (!mounted) return;
    setState(() {
      _diaries = entries;
      _diaryLoading = false;
    });
  }

  Future<void> _loadWhispers() async {
    final entries = await widget.whisperLoader(onCached: _showCachedWhispers);
    if (!mounted) return;
    setState(() {
      _whispers = entries;
      _whisperLoading = false;
    });
  }

  void _showCachedWhispers(List<Whisper> entries) {
    if (!mounted) return;
    setState(() {
      _whispers = entries;
      _whisperLoading = false;
    });
  }

  Future<void> _loadContemplationCount() async {
    final count = await widget.contemplationCountLoader(
      onCached: _showCachedContemplationCount,
    );
    if (!mounted) return;
    setState(() {
      _contemplationCount = count;
      _contemplationLoading = false;
    });
  }

  void _showCachedContemplationCount(int count) {
    if (!mounted) return;
    setState(() {
      _contemplationCount = count;
      _contemplationLoading = false;
    });
  }

  void _open(Widget page) {
    Navigator.of(context).push(SwipeBackRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(title: const Text('个人内容')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        children: [
          _ContentPreviewCard(
            key: const ValueKey('diary_preview'),
            icon: LucideIcons.book_open,
            title: '日记',
            onTap: () => _open(const DiaryListPage()),
            child: _diarySummary(context),
          ),
          const SizedBox(height: AppSpacing.md),
          _ContentPreviewCard(
            key: const ValueKey('whisper_preview'),
            icon: LucideIcons.heart,
            title: '想说的话',
            onTap: () => _open(const WhisperListPage()),
            child: _whisperSummary(context),
          ),
          const SizedBox(height: AppSpacing.md),
          _ContentPreviewCard(
            key: const ValueKey('contemplation_preview'),
            icon: LucideIcons.moon,
            title: '沉思室',
            onTap: () => _open(const ContemplationPage()),
            child: _contemplationSummary(context),
          ),
        ],
      ),
    );
  }

  Widget _diarySummary(BuildContext context) {
    if (_diaryLoading) return _statusText(context, '读取中');
    final entries = _diaries;
    if (entries == null) return _statusText(context, '暂时无法读取');
    if (entries.isEmpty) return _statusText(context, '还没有日记');

    final latest = entries.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                latest.title.isEmpty ? '无题' : latest.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (latest.date.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                latest.date,
                style: TextStyle(
                  fontSize: AppType.timestamp,
                  color: context.subTextColor,
                ),
              ),
            ],
          ],
        ),
        if (latest.content.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            latest.content,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.caption,
              height: 1.45,
              color: context.subTextColor,
            ),
          ),
        ],
      ],
    );
  }

  Widget _whisperSummary(BuildContext context) {
    if (_whisperLoading) return _statusText(context, '读取中');
    final entries = _whispers;
    if (entries == null) return _statusText(context, '暂时无法读取');
    if (entries.isEmpty) return _statusText(context, '还没有想说的话');

    final latest = _latestWhisper(entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          latest.content,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: AppType.body, height: 1.45),
        ),
        if (latest.createdAt.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            memTimeFull(latest.createdAt.replaceFirst(' ', 'T')),
            style: TextStyle(
              fontSize: AppType.timestamp,
              color: context.subTextColor,
            ),
          ),
        ],
      ],
    );
  }

  Widget _contemplationSummary(BuildContext context) {
    if (_contemplationLoading) return _statusText(context, '读取中');
    final count = _contemplationCount;
    if (count == null) return _statusText(context, '次数暂时未知');
    return Text(
      '已独坐 $count 次',
      style: const TextStyle(
        fontSize: AppType.body,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _statusText(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(fontSize: AppType.caption, color: context.subTextColor),
    );
  }

  static Whisper _latestWhisper(List<Whisper> entries) {
    final sorted = [...entries]
      ..sort((a, b) {
        final aTime = _parseTime(a.createdAt)?.millisecondsSinceEpoch ?? 0;
        final bTime = _parseTime(b.createdAt)?.millisecondsSinceEpoch ?? 0;
        final byTime = bTime.compareTo(aTime);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });
    return sorted.first;
  }

  static DateTime? _parseTime(String raw) =>
      DateTime.tryParse(raw.trim().replaceFirst(' ', 'T'));
}

class _ContentPreviewCard extends StatelessWidget {
  const _ContentPreviewCard({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    required this.child,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 22, color: context.accentColor),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 20,
                      color: context.semanticColors.outline,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
