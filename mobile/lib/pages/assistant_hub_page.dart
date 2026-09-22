import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/mood.dart';
import '../services/mood_api.dart';
import '../services/profile_api.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'assistant_channel_page.dart';
import 'mood_page.dart';
import 'personal_space_page.dart';
import 'profile_page.dart';
import 'system_prompt_page.dart';

typedef MoodSummaryLoader =
    Future<MoodEntry?> Function({void Function(MoodEntry mood)? onCached});

/// AI 助手的人物入口：资料、当前心情和两项高价值内容。
class AssistantHubPage extends StatefulWidget {
  const AssistantHubPage({super.key, this.moodLoader = MoodApi.current});

  final MoodSummaryLoader moodLoader;

  @override
  State<AssistantHubPage> createState() => _AssistantHubPageState();
}

class _AssistantHubPageState extends State<AssistantHubPage> {
  MoodEntry? _mood;
  bool _moodLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMood();
  }

  Future<void> _loadMood() async {
    final mood = await widget.moodLoader(onCached: _showCachedMood);
    if (!mounted) return;
    setState(() {
      _mood = mood;
      _moodLoading = false;
    });
  }

  void _showCachedMood(MoodEntry mood) {
    if (!mounted) return;
    setState(() {
      _mood = mood;
      _moodLoading = false;
    });
  }

  void _open(Widget page) {
    Navigator.of(context).push(SwipeBackRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(title: const Text('AI 助手')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        children: [
          ListenableBuilder(
            listenable: ProfileManager.instance,
            builder: (context, _) => _AssistantHero(
              name: ProfileManager.instance.youName,
              avatarUrl: ProfileManager.instance.youAvatar,
              onTap: () => _open(const ProfilePage()),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _MoodPreview(
            mood: _mood,
            loading: _moodLoading,
            onTap: () => _open(const MoodPage()),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _AssistantAction(
                  key: const ValueKey('assistant_personal_space'),
                  icon: LucideIcons.heart,
                  label: '个人内容',
                  onTap: () => _open(const PersonalSpacePage()),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _AssistantAction(
                  key: const ValueKey('assistant_preferences'),
                  icon: LucideIcons.heart_handshake,
                  label: '相处偏好',
                  onTap: () => _open(const SystemPromptPage()),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _AssistantChannelAction(
            onTap: () => _open(const AssistantChannelPage()),
          ),
        ],
      ),
    );
  }
}

class _AssistantChannelAction extends StatelessWidget {
  const _AssistantChannelAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('assistant_assistant_channel'),
      color: context.cardColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.messages_square,
                size: 23,
                color: context.accentColor,
              ),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text(
                  'AI 协作记录',
                  style: TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                LucideIcons.lock,
                size: 16,
                color: context.semanticColors.mutedText,
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

class _AssistantHero extends StatelessWidget {
  const _AssistantHero({
    required this.name,
    required this.avatarUrl,
    required this.onTap,
  });

  final String name;
  final String avatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      key: const ValueKey('assistant_profile_hero'),
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
            child: Row(
              children: [
                _AssistantAvatar(url: avatarUrl, size: 88),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 助手',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.subTextColor,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: context.textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  LucideIcons.chevron_right,
                  size: 22,
                  color: context.semanticColors.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Image.asset(
      'assets/icon-continuum.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: url.isEmpty
            ? fallback
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholder: (_, _) => ColoredBox(color: context.fieldColor),
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _MoodPreview extends StatelessWidget {
  const _MoodPreview({
    required this.mood,
    required this.loading,
    required this.onTap,
  });

  final MoodEntry? mood;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final entry = mood;
    final label = loading
        ? '正在读取'
        : entry == null || entry.label.isEmpty
        ? '暂时未知'
        : entry.label;

    return Material(
      key: const ValueKey('assistant_mood_preview'),
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
                width: 40,
                child: entry != null && entry.emoji.isNotEmpty
                    ? Text(entry.emoji, style: const TextStyle(fontSize: 30))
                    : Icon(
                        LucideIcons.smile,
                        size: 26,
                        color: context.semanticColors.mutedText,
                      ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前心情',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: context.subTextColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (entry != null && entry.note.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        entry.note,
                        key: const ValueKey('assistant_mood_note'),
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

class _AssistantAction extends StatelessWidget {
  const _AssistantAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.md,
          ),
          child: Column(
            children: [
              Icon(icon, size: 24, color: context.accentColor),
              const SizedBox(height: AppSpacing.sm),
              Text(
                label,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
