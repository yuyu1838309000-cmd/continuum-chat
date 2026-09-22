import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/reading_book.dart';
import '../services/music_player.dart';
import '../services/together_summary_service.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'bottle_page.dart';
import 'music_page.dart';
import 'pixel_home_page.dart';
import 'reading_page.dart';
import 'travel_page.dart';

/// 共同活动的内容首页：先看此刻状态，再进入对应空间。
class TogetherHubPage extends StatefulWidget {
  const TogetherHubPage({
    super.key,
    this.homeLoader = TogetherSummaryService.home,
    this.readingLoader = TogetherSummaryService.reading,
    this.travelLoader = TogetherSummaryService.travel,
    this.musicListenable,
    this.musicReader = TogetherSummaryService.music,
  });

  final TogetherHomeSummaryLoader homeLoader;
  final TogetherReadingSummaryLoader readingLoader;
  final TogetherTravelSummaryLoader travelLoader;
  final Listenable? musicListenable;
  final TogetherMusicSummaryReader musicReader;

  @override
  State<TogetherHubPage> createState() => _TogetherHubPageState();
}

class _TogetherHubPageState extends State<TogetherHubPage> {
  TogetherHomeSummary? _home;
  TogetherReadingSummary? _reading;
  TogetherTravelSummary? _travel;
  bool _homeLoading = true;
  bool _readingLoading = true;
  bool _travelLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHome();
    _loadReading();
    _loadTravel();
  }

  Future<void> _loadHome() async {
    TogetherHomeSummary? summary;
    try {
      summary = await widget.homeLoader(onCached: _showCachedHome);
    } catch (_) {
      summary = null;
    }
    if (!mounted) return;
    setState(() {
      _home = summary ?? _home;
      _homeLoading = false;
    });
  }

  Future<void> _loadReading() async {
    TogetherReadingSummary? summary;
    try {
      summary = await widget.readingLoader(onCached: _showCachedReading);
    } catch (_) {
      summary = null;
    }
    if (!mounted) return;
    setState(() {
      _reading = summary ?? _reading;
      _readingLoading = false;
    });
  }

  Future<void> _loadTravel() async {
    TogetherTravelSummary? summary;
    try {
      summary = await widget.travelLoader(onCached: _showCachedTravel);
    } catch (_) {
      summary = null;
    }
    if (!mounted) return;
    setState(() {
      _travel = summary ?? _travel;
      _travelLoading = false;
    });
  }

  void _showCachedHome(TogetherHomeSummary summary) {
    if (!mounted) return;
    setState(() {
      _home = summary;
      _homeLoading = false;
    });
  }

  void _showCachedReading(TogetherReadingSummary summary) {
    if (!mounted) return;
    setState(() {
      _reading = summary;
      _readingLoading = false;
    });
  }

  void _showCachedTravel(TogetherTravelSummary summary) {
    if (!mounted) return;
    setState(() {
      _travel = summary;
      _travelLoading = false;
    });
  }

  void _open(Widget page) {
    Navigator.of(context).push(SwipeBackRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(title: const Text('一起')),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HomeHero(
                summary: _home,
                loading: _homeLoading,
                onTap: () => _open(const PixelHomePage()),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                '此刻一起',
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w500,
                  color: context.semanticColors.mutedText,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ListenableBuilder(
                listenable: widget.musicListenable ?? MusicPlayer.instance,
                builder: (context, _) => _MusicPreview(
                  summary: widget.musicReader(),
                  onTap: () => _open(const MusicPage()),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _ReadingPreview(
                summary: _reading,
                loading: _readingLoading,
                onTap: () => _open(const ReadingPage()),
              ),
              const SizedBox(height: AppSpacing.sm),
              _TravelPreview(
                summary: _travel,
                loading: _travelLoading,
                onTap: () => _open(const TravelPage()),
              ),
              const SizedBox(height: AppSpacing.md),
              _BottleEntry(onTap: () => _open(const BottlePage())),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeHero extends StatelessWidget {
  const _HomeHero({
    required this.summary,
    required this.loading,
    required this.onTap,
  });

  final TogetherHomeSummary? summary;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final people = summary?.people ?? const <TogetherHomePersonSummary>[];
    return DecoratedBox(
      key: const ValueKey('together_home_hero'),
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
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.fieldColor,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: const SizedBox.square(
                        dimension: 44,
                        child: Icon(LucideIcons.house, size: 22),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    const Expanded(
                      child: Text(
                        '小家',
                        style: TextStyle(
                          fontSize: AppType.title,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 22,
                      color: context.semanticColors.outline,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                if (loading)
                  _MutedLine('正在看看家里', key: const ValueKey('home_loading'))
                else if (summary == null)
                  const _MutedLine('暂时没读到家里的动静')
                else if (people.isEmpty)
                  const _MutedLine('家里此刻安安静静')
                else
                  for (var index = 0; index < people.length; index++) ...[
                    if (index > 0) const SizedBox(height: AppSpacing.sm),
                    _HomePersonLine(person: people[index]),
                  ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomePersonLine extends StatelessWidget {
  const _HomePersonLine({required this.person});

  final TogetherHomePersonSummary person;

  @override
  Widget build(BuildContext context) {
    final status = [
      if (person.room.isNotEmpty) person.room,
      if (person.action.isNotEmpty) person.action,
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Text(
            person.name,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600,
              color: context.subTextColor,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            status.isEmpty ? '此刻没有留下状态' : status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: AppType.body, height: 1.35),
          ),
        ),
      ],
    );
  }
}

class _MusicPreview extends StatelessWidget {
  const _MusicPreview({required this.summary, required this.onTap});

  final TogetherMusicSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ActivityPreview(
      key: const ValueKey('together_music_preview'),
      icon: LucideIcons.music,
      label: '一起听',
      title: summary.hasSong ? summary.title : '还没有在播放',
      detail: summary.hasSong
          ? [
              if (summary.artist.isNotEmpty) summary.artist,
              summary.playing ? '正在播放' : '已暂停',
            ].join(' · ')
          : '',
      muted: !summary.hasSong,
      onTap: onTap,
    );
  }
}

class _ReadingPreview extends StatelessWidget {
  const _ReadingPreview({
    required this.summary,
    required this.loading,
    required this.onTap,
  });

  final TogetherReadingSummary? summary;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final book = summary?.book;
    final title = loading
        ? '正在读取'
        : summary == null
        ? '暂时没读到共读状态'
        : book == null
        ? '还没有正在看的书'
        : book.title;
    return _ActivityPreview(
      key: const ValueKey('together_reading_preview'),
      icon: LucideIcons.book_open,
      label: '一起读',
      title: title,
      detail: book == null ? '' : _readingDetail(book, summary!.activeCount),
      muted: book == null,
      onTap: onTap,
    );
  }

  static String _readingDetail(ReadingBook book, int count) {
    final chapter = book.participantLastChapter.isNotEmpty
        ? '用户读到 ${book.participantLastChapter}'
        : book.assistantLastChapter.isNotEmpty
        ? 'AI 助手读到 ${book.assistantLastChapter}'
        : '';
    return [
      if (book.author.isNotEmpty) book.author,
      if (chapter.isNotEmpty) chapter,
      if (count > 1) '另有 ${count - 1} 本正在看',
    ].join(' · ');
  }
}

class _TravelPreview extends StatelessWidget {
  const _TravelPreview({
    required this.summary,
    required this.loading,
    required this.onTap,
  });

  final TogetherTravelSummary? summary;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasContent = summary?.hasContent == true;
    final title = loading
        ? '正在读取'
        : summary == null
        ? '暂时没读到旅行近况'
        : hasContent
        ? summary!.title
        : '还没有新的旅途';
    return _ActivityPreview(
      key: const ValueKey('together_travel_preview'),
      icon: summary?.fromPostcard == true ? LucideIcons.mail : LucideIcons.map,
      label: '旅行',
      title: title,
      detail: hasContent ? summary!.detail : '',
      muted: !hasContent,
      onTap: onTap,
    );
  }
}

class _ActivityPreview extends StatelessWidget {
  const _ActivityPreview({
    super.key,
    required this.icon,
    required this.label,
    required this.title,
    required this.detail,
    required this.muted,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String title;
  final String detail;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.layerColor,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                child: Icon(
                  icon,
                  size: 21,
                  color: context.semanticColors.mutedText,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
                        color: context.subTextColor,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
                        color: muted ? context.subTextColor : context.textColor,
                        height: 1.3,
                      ),
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.subTextColor,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                LucideIcons.chevron_right,
                size: 20,
                color: context.semanticColors.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottleEntry extends StatelessWidget {
  const _BottleEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.bottle_wine,
                size: 20,
                color: context.semanticColors.mutedText,
              ),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text(
                  '提问瓶',
                  style: TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w500,
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
        ),
      ),
    );
  }
}

class _MutedLine extends StatelessWidget {
  const _MutedLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: AppType.body, color: context.subTextColor),
    );
  }
}
