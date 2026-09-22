import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

/// 图片全屏预览页：黑底 + InteractiveViewer 双指缩放（参考 RikkaHub
/// ZoomableAsyncImage 思路）+ 点击/返回关闭。
class ImagePreviewPage extends StatelessWidget {
  final String url;

  const ImagePreviewPage({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scrimColor,
      body: GestureDetector(
        // 点击关闭（双指缩放时 InteractiveViewer 自己处理，不冲突）
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(
          maxScale: 5,
          minScale: 1,
          child: Center(
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (context, url) => const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
              errorWidget: (_, _, _) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 48,
                  color: Colors.white38,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
