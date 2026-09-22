import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/personal_space.dart';
import '../utils/app_theme.dart';
import '../utils/diary_mood.dart';

/// 日记详情页：元信息退后，正文保持舒展的阅读宽度与行距。
class DiaryDetailPage extends StatelessWidget {
  final DiaryEntry entry;

  const DiaryDetailPage({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        appBar: AppBar(
          title: const Text('日记'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.title.isEmpty ? '无题' : entry.title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (entry.date.isNotEmpty)
                    Text(
                      entry.date,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: context.subTextColor,
                      ),
                    ),
                  if (entry.weather.isNotEmpty) ...[
                    Text(
                      entry.weather,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: context.subTextColor,
                      ),
                    ),
                  ],
                  if (entry.mood.isNotEmpty) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: diaryMoodColor(entry.moodScore),
                            shape: BoxShape.circle,
                          ),
                          child: const SizedBox(width: 8, height: 8),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          entry.mood,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: context.subTextColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              if (entry.content.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xl),
                SelectionArea(
                  child: Text(
                    entry.content,
                    key: const ValueKey('diary_body'),
                    style: TextStyle(
                      fontSize: 17,
                      height: 1.9,
                      color: context.textColor,
                    ),
                    softWrap: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
