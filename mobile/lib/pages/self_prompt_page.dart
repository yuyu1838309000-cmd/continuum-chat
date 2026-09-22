import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'self_prompt_memory_page.dart';
import 'self_prompt_system_page.dart';

/// 长期说明：身份与性格 + 想记住的事。
/// 数据读写 8816 /self-prompt。样式走基准简洁卡片（圆角20 + 柔和阴影 +
/// cardColor + 无小字），跟系统记忆管理/记忆面板一致。
class SelfPromptPage extends StatelessWidget {
  const SelfPromptPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('长期说明')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _entryCard(
            context,
            icon: LucideIcons.user_round,
            title: '身份与性格',
            onTap: () => Navigator.of(context).push(
              SwipeBackRoute(builder: (_) => const SelfPromptSystemPage()),
            ),
          ),
          _entryCard(
            context,
            icon: LucideIcons.sticky_note,
            title: '想记住的事',
            onTap: () => Navigator.of(context).push(
              SwipeBackRoute(builder: (_) => const SelfPromptMemoryPage()),
            ),
          ),
        ],
      ),
    );
  }

  /// 入口卡片：圆角 20 + 柔和阴影 + cardColor 底，左 Icon 24 + 标题 15 w600 +
  /// 右侧 chevron 22，无小字（基准简洁卡片，跟系统记忆管理一致）。
  Widget _entryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, size: 24, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
                Icon(
                  LucideIcons.chevron_right,
                  size: 22,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
