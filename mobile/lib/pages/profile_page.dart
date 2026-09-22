import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/image_crop_service.dart';
import '../services/profile_api.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'self_prompt_page.dart';

/// 双方人物资料：AI 助手在前、用户在后，保留头像与备注的完整编辑能力。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _meCtrl;
  late final TextEditingController _youCtrl;
  final ImagePicker _picker = ImagePicker();

  // 正在上传的头像侧（me/you），显示转圈
  String? _uploading;

  @override
  void initState() {
    super.initState();
    _meCtrl = TextEditingController(text: ProfileManager.instance.meName);
    _youCtrl = TextEditingController(text: ProfileManager.instance.youName);
  }

  @override
  void dispose() {
    _meCtrl.dispose();
    _youCtrl.dispose();
    super.dispose();
  }

  /// 保存备注：两个输入框非空值提交服务器，成功 toast。
  Future<void> _save() async {
    final ok = await ProfileManager.instance.setNames(
      meName: _meCtrl.text,
      youName: _youCtrl.text,
    );
    if (!mounted) return;
    _toast(ok ? '已保存' : '保存失败，检查网络');
  }

  /// 点头像弹底部菜单：相册选图 / 恢复默认（发光猫）。
  void _pickAvatar(String who) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    who == 'me' ? '我的头像' : 'AI 助手的头像',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              _avatarActionRow(
                sheetContext: ctx,
                icon: LucideIcons.image,
                title: '从相册选一张',
                onTap: () {
                  Navigator.pop(ctx);
                  _uploadFromGallery(who);
                },
              ),
              _avatarActionRow(
                sheetContext: ctx,
                icon: LucideIcons.cat,
                title: '恢复默认（发光猫）',
                onTap: () {
                  Navigator.pop(ctx);
                  _uploadDefaultCat(who);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _avatarActionRow({
    required BuildContext sheetContext,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(sheetContext);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Material(
        color: sheetContext.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 22, color: theme.colorScheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  LucideIcons.chevron_right,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 相册选图 → 裁剪 → 上传。
  Future<void> _uploadFromGallery(String who) async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 88,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final cropped = await ImageCropService.cropSquareBytes(
        bytes,
        title: who == 'me' ? '裁剪我的头像' : '裁剪AI 助手头像',
      );
      if (cropped == null) return;
      await _upload(who, cropped);
    } catch (_) {
      if (mounted) _toast('选图失败');
    }
  }

  /// 恢复默认：把打包的发光猫传上去（服务器头像重置为默认）。
  Future<void> _uploadDefaultCat(String who) async {
    try {
      final data = await rootBundle.load('assets/icon-continuum.png');
      await _upload(who, data.buffer.asUint8List());
    } catch (_) {
      if (mounted) _toast('恢复失败');
    }
  }

  Future<void> _upload(String who, Uint8List bytes) async {
    setState(() => _uploading = who);
    final ok = await ProfileManager.instance.uploadAvatar(
      who: who,
      bytes: bytes,
    );
    if (!mounted) return;
    setState(() => _uploading = null);
    _toast(ok ? '头像已更新' : '上传失败，检查网络');
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
            borderRadius: BorderRadius.circular(14),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          elevation: 0,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('资料'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
              ),
              onPressed: _save,
              child: const Text('保存', style: TextStyle(fontSize: AppType.body)),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: ProfileManager.instance,
        builder: (context, _) {
          final mgr = ProfileManager.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            children: [
              _personCard(
                title: 'AI 助手',
                url: mgr.youAvatar,
                who: 'you',
                uploading: _uploading == 'you',
                controller: _youCtrl,
                fieldLabel: '名字',
              ),
              const SizedBox(height: AppSpacing.md),
              _personCard(
                title: '用户',
                url: mgr.meAvatar,
                who: 'me',
                uploading: _uploading == 'me',
                controller: _meCtrl,
                fieldLabel: '名字',
              ),
              const SizedBox(height: AppSpacing.lg),
              _selfPromptCard(),
            ],
          );
        },
      ),
    );
  }

  /// 长期说明入口卡：点进身份与性格、想记住的事。
  Widget _selfPromptCard() {
    return Material(
      color: context.layerColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(SwipeBackRoute(builder: (_) => const SelfPromptPage())),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                LucideIcons.user_round,
                size: 24,
                color: context.subTextColor,
              ),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Text(
                  '长期说明',
                  style: TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w600,
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
        ),
      ),
    );
  }

  Widget _personCard({
    required String title,
    required String url,
    required String who,
    required bool uploading,
    required TextEditingController controller,
    required String fieldLabel,
  }) {
    final theme = Theme.of(context);
    final overlaySpinnerColor = context.isDark
        ? theme.colorScheme.onSurface
        : theme.colorScheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: AppType.title,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Semantics(
                    button: true,
                    label: '$title头像',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _pickAvatar(who),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _roundAvatar(url, size: 76),
                          if (uploading)
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: context.scrimColor.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                                child: Center(
                                  child: SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: overlaySpinnerColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: theme.colorScheme.primary,
                                border: Border.all(
                                  color: context.cardColor,
                                  width: 2,
                                ),
                              ),
                              child: SizedBox.square(
                                dimension: 28,
                                child: Icon(
                                  LucideIcons.camera,
                                  size: 14,
                                  color: theme.colorScheme.onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      maxLength: 20,
                      decoration: InputDecoration(
                        labelText: fieldLabel,
                        counterText: '',
                        filled: true,
                        fillColor: context.fieldColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 圆形头像：URL 有就网络加载（失败回退发光猫），空用本地发光猫。
  Widget _roundAvatar(String url, {required double size}) {
    final fallback = Image.asset(
      'assets/icon-continuum.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? fallback
            : CachedNetworkImage(
                imageUrl: url,
                width: size,
                height: size,
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
