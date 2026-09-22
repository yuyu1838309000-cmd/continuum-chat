import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 服务器地址配置页（配置中心 · 服务器地址卡片）
/// - 填 host（默认 127.0.0.1），保存后 App 所有请求立即切到新地址
/// - 换服务器不用重新编译
class ServerConfigPage extends StatefulWidget {
  const ServerConfigPage({super.key});

  @override
  State<ServerConfigPage> createState() => _ServerConfigPageState();
}

class _ServerConfigPageState extends State<ServerConfigPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ServerConfig.instance.host);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final saved = await ServerConfig.instance.setHost(_ctrl.text);
    if (!mounted) return;
    if (!saved) {
      _toast('只填 IP/域名，不要带端口或路径');
      return;
    }
    setState(() {}); // 刷新预览
    _toast('已保存，新地址立即生效');
  }

  void _toast(String msg) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 13)),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          elevation: 0,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('服务器地址')),
      body: ListenableBuilder(
        listenable: ServerConfig.instance,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              // 说明（字少，克制）
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text(
                  '改这里换服务器，不用重新编译。保存后聊天、资料、工具箱全部切到新地址。',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 服务器地址
              const AppSectionLabel('服务器地址', compact: true),
              SettingCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _ctrl,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: ServerConfig.defaultHost,
                        prefixIcon: const Icon(LucideIcons.server, size: 20),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(LucideIcons.save, size: 18),
                        label: const Text('保存并生效'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    // 当前生效地址预览
                    Text(
                      '当前生效：${ServerConfig.runtimeUrl('')}',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
