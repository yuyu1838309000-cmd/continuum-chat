import 'package:flutter/material.dart';
import '../services/tool_registry.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';
import '../services/nudge_api.dart';
import 'dashboard_page.dart';
import 'memory_query_page.dart';
import 'nudge_tools_page.dart';

/// 分类页（工具箱二级）：一个分类下的各小卡片。
/// - 每工具一张共用导航卡片，保留分类内的直接详情入口
/// - 面板只放已接通的工具，点卡片直接进详情页
/// - 简洁清爽，不带 emoji
class ToolCategoryPage extends StatelessWidget {
  final ToolModule module;

  const ToolCategoryPage({super.key, required this.module});

  /// 点卡片：已接通的工具直接进详情页。
  void _openTool(BuildContext context, ToolEntry t) {
    switch (t.id) {
      case 'server':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const DashboardPage()));
      case 'memory':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MemoryQueryPage()));
      // 手机工具兜底：进独立板块页（正常入口是工具箱 → 手机卡片）
      case _ when NudgeApi.all.contains(t.id):
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const NudgeToolsPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(module.title)),
      body: ListenableBuilder(
        listenable: ToolRegistry.instance,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              // 小卡片：每工具一张，点进详情页
              for (final t in module.tools)
                AppNavigationCard(
                  icon: t.icon,
                  title: t.name,
                  showChevron: false,
                  onTap: () => _openTool(context, t),
                ),
              const SizedBox(height: AppSpacing.xs),
            ],
          );
        },
      ),
    );
  }
}
