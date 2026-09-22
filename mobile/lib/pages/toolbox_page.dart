import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/tool_registry.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';
import 'nudge_tools_page.dart';
import 'tool_category_page.dart';
import 'my_plugins_page.dart';

/// 工具箱页（v5：只显示已接通的工具）。
/// - 大分类卡片复用 AppNavigationCard，点击进分类页
/// - 面板只放已接通的真实工具（查记忆/看服务器），没有"建设中"占位
/// - 简洁清爽：分类不带 emoji
class ToolboxPage extends StatelessWidget {
  const ToolboxPage({super.key, this.title = '工具箱'});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListenableBuilder(
        listenable: ToolRegistry.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            // 大分类卡片：每模块一张，点击进分类页（模块来自服务器清单，动态渲染）
            for (final m in ToolRegistry.modules)
              AppNavigationCard(
                icon: m.tools.first.icon,
                title: m.title,
                onTap: () {
                  final page = m.title == '手机'
                      ? const NudgeToolsPage()
                      : ToolCategoryPage(module: m);
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => page));
                },
              ),
            AppNavigationCard(
              icon: LucideIcons.package,
              title: '插件',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MyPluginsPage()),
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
