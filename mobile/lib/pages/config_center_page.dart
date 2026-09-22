import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';
import '../widgets/swipe_back.dart';
import 'model_config_page.dart';
import 'ocr_config_page.dart';
import 'gen_image_config_page.dart';
import 'server_config_page.dart';
import 'stt_config_page.dart';
import 'search_config_page.dart';
import 'tts_config_page.dart';
import 'context_layout_page.dart';
import 'history_migration_preview_page.dart';
import 'reading_probe_page.dart';
import 'tool_tester_page.dart';

/// 高级设置页：集中承接技术配置与开发诊断入口。
/// 入口复用 AppNavigationCard，无 subtitle 小字，点击进各分类独立配置页。
class ConfigCenterPage extends StatelessWidget {
  const ConfigCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置')),
      // 服务器地址卡片要显示当前 host，监听 ServerConfig
      body: ListenableBuilder(
        listenable: ServerConfig.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            AppNavigationCard(
              icon: LucideIcons.brain_cog,
              title: '模型',
              onTap: () {
                Navigator.of(
                  context,
                ).push(SwipeBackRoute(builder: (_) => const ModelConfigPage()));
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.scan_text,
              title: 'OCR',
              onTap: () {
                Navigator.of(
                  context,
                ).push(SwipeBackRoute(builder: (_) => const OcrConfigPage()));
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.audio_lines,
              title: 'TTS',
              onTap: () {
                Navigator.of(
                  context,
                ).push(SwipeBackRoute(builder: (_) => const TtsConfigPage()));
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.image,
              title: '图片生成',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const GenImageConfigPage()),
                );
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.mic,
              title: '语音转文字',
              onTap: () {
                Navigator.of(
                  context,
                ).push(SwipeBackRoute(builder: (_) => const SttConfigPage()));
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.search,
              title: '搜索',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const SearchConfigPage()),
                );
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.server,
              title: '服务器地址',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const ServerConfigPage()),
                );
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.layout_grid,
              title: '上下文拼接',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const ContextLayoutPage()),
                );
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.flask_conical,
              title: '工具测试器',
              onTap: () {
                Navigator.of(
                  context,
                ).push(SwipeBackRoute(builder: (_) => const ToolTesterPage()));
              },
            ),
            AppNavigationCard(
              icon: LucideIcons.book_open_check,
              title: '共读探针',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const ReadingProbePage()),
                );
              },
            ),
            if (ServerConfig.isCandidateRuntime)
              AppNavigationCard(
                icon: LucideIcons.history,
                title: '历史迁移预演',
                onTap: () {
                  Navigator.of(context).push(
                    SwipeBackRoute(
                      builder: (_) => const HistoryMigrationPreviewPage(),
                    ),
                  );
                },
              ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ),
      ),
    );
  }
}
