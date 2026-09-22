import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../utils/time_format.dart';
import '../utils/app_theme.dart';
import '../utils/chat_process_copy.dart';
import 'search_bubble.dart';
import 'selection_toolbar.dart';
import '../pages/image_preview_page.dart';
import '../services/gallery_saver.dart';
import '../services/tts_api.dart';
import '../services/profile_api.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// 一条消息渲染为一组气泡，一个段落一个气泡（胶囊形）。
/// v0.2.96 起每个段落气泡（含图片/代码块/搜索中气泡）各配自己的头像：
/// AI 助手（assistant）头像在左、用户（user）头像在右，段落变化时头像跟着段落一起进出，
/// 不单独跳动。时间戳/用量/停顿点等元信息行在最后一段下方，不带头像。
/// 气泡下方带时间戳小字：同一天 [14:30]，跨天 [08-05 22:10]。
/// assistant 消息带思考内容时，时间戳旁显示空心气泡轮廓图标（chat_bubble_outline），
/// 点击展开半透明面板看思考过程。
class MessageBubble extends StatelessWidget {
  /// 头像侧缩进：头像宽 32 + 头像-气泡间距 6，元信息行沿此缩进与正文气泡对齐
  static const double _avatarInset = 38;

  final ChatMessage message;
  final bool isMe;
  final DateTime? prevTime;

  /// 流式输出中：消息还没发完，不显示时间戳和思考链（发完才显示）
  final bool streaming;

  /// 长按操作回调（合并进系统选择工具栏）：复制整条 / 重新生成 / 删除
  final VoidCallback? onCopyAll;
  final VoidCallback? onRegenerate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// 图片发送失败占位气泡点击回调（弹重试/删除菜单），发送中态为空。
  final VoidCallback? onImageSendTap;

  /// 文件发送失败占位卡片点击回调（弹重试/删除菜单），发送中态为空。
  final VoidCallback? onFileSendTap;

  /// 文本消息发送失败：点感叹号回到输入框重新编辑。
  final VoidCallback? onSendFailedTap;

  /// 显示 token 用量（命中率）：模型配置页开关控制，assistant 消息有 usage 时显示
  final bool showTokenUsage;

  /// 是否显示气泡下方时间戳，设置页控制，默认显示。
  final bool showTimestamp;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.prevTime,
    this.streaming = false,
    this.onCopyAll,
    this.onRegenerate,
    this.onEdit,
    this.onDelete,
    this.onImageSendTap,
    this.onFileSendTap,
    this.onSendFailedTap,
    this.showTokenUsage = false,
    this.showTimestamp = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // tool_done 工具完成标记（v0.2.168）："✓ 搞定了！"居中低调小气泡，
    // 永久保留在对话流，样式同 busy 占位；不走普通气泡（不显示头像/操作菜单）
    if (message.isToolDone) {
      return toolDoneCard(theme, label: message.content);
    }
    // activity 消息（静默活动动态）：居中低调小卡片，独立渲染，
    // 不走普通气泡（不显示头像/思考链/朗读/操作菜单）
    if (message.isActivity) {
      return activityCard(
        theme,
        message,
        prevTime,
        showTimestamp: showTimestamp,
      );
    }
    // 图片发送中/失败占位气泡：点发送后消息流立即出现（带头像/缩略图/状态），
    // 上传+OCR 完成后由 chat_page 原地升级成真实图片消息（同一条消息，不跳位）
    if (message.imageSendStatus != null) {
      return _buildPendingImageBubble(context, theme);
    }
    // 文件发送中/失败占位：文件卡片 + 状态（上传+内容提取中/失败可重试）
    if (message.fileSendStatus != null) {
      return _buildPendingFileBubble(context, theme);
    }
    // v0.2.160：assistant（AI 助手）消息按 ``` 代码块 + 普通文本先拆段，普通文本再按自然段
    // 拆成一个段落一个气泡（标题/引用跟随所在段落，代码块整块渲染）；用户消息照旧按
    // ``` 拆段，普通文本一行一气泡。
    // v0.2.164：文件消息 content 现在只放用户配的字（模型侧标注改由 ChatApi 拼接），
    // 配字照常显示；过滤掉空配字兜底占位 '[文件]'，别把占位当正文显示。
    // v0.2.165：图片消息同款处理，空配字兜底占位 '[图片]' 只在纯图消息过滤
    // （配字正常显示，纯文本消息里的字面 '[图片]' 也不受影响）。
    final isFileMessage =
        message.fileUrl != null && message.fileUrl!.isNotEmpty;
    final isImageMessage =
        (message.imageUrl != null && message.imageUrl!.isNotEmpty) ||
        message.imageUrls.isNotEmpty;
    final blocks = _splitBlocks(message.content)
        .where(
          (b) =>
              !(isFileMessage && b.text.trim() == '[文件]') &&
              !(isImageMessage && b.text.trim() == '[图片]'),
        )
        .toList();

    // 气泡 identity 是独立语义角色：AI 助手左、用户右，不与 field/card 混用。
    final bgColor = isMe
        ? context.userBubbleColor
        : context.assistantBubbleColor;
    final fgColor = isMe
        ? context.onUserBubbleColor
        : context.onAssistantBubbleColor;

    // 胶囊形：短消息接近胶囊，长消息自然成为柔和圆角矩形。
    final radius = Radius.circular(21);
    final tail = const Radius.circular(9);

    // 柔和浅阴影：低透明度、大模糊、小偏移，别重
    final shadow = context.cardShadow;

    final timestamp = formatMessageTime(message.time, prevTime);
    // 内容为空（打字机还没吐字/空占位）时不渲染整个气泡，避免"时间戳比内容先出现"。
    // 注意：纯图片消息 content 空但 imageUrl 有值，不能提前 return（否则整条消息空白）
    if ((blocks.isEmpty || message.content.trim().isEmpty) &&
        !message.searching &&
        !message.searchDone &&
        (message.imageUrl == null || message.imageUrl!.isEmpty) &&
        message.imageUrls.isEmpty &&
        (message.fileUrl == null || message.fileUrl!.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // 图片消息：有 imageUrl 时在气泡内容上方渲染图片（圆角 20 跟气泡一致），
          // 点击全屏预览 + 双指缩放
          if (message.imageUrl != null && message.imageUrl!.isNotEmpty)
            _avatarRow(_buildImageBlock(context, theme)),
          // 多选发图：竖向依次渲染每张（各自可点全屏），OCR 只合并给模型不逐张显示
          if (message.imageUrls.isNotEmpty)
            for (var i = 0; i < message.imageUrls.length; i++)
              i == 0
                  ? _avatarRow(
                      _buildImageBlockFor(
                        context,
                        theme,
                        message.imageUrls[i],
                        bottom: i == message.imageUrls.length - 1
                            ? (message.content.trim().isEmpty ? 0 : 10)
                            : 8,
                      ),
                    )
                  : Padding(
                      padding: _avatarSideInset(),
                      child: _buildImageBlockFor(
                        context,
                        theme,
                        message.imageUrls[i],
                        bottom: i == message.imageUrls.length - 1
                            ? (message.content.trim().isEmpty ? 0 : 10)
                            : 8,
                      ),
                    ),
          // OCR 是图片的辅助信息，不重复头像，也不默认把识别全文摊在聊天流里。
          if (message.ocrText != null && message.ocrText!.isNotEmpty)
            Padding(
              padding: _avatarSideInset(),
              child: _OcrCaption(text: message.ocrText!),
            ),
          // 文件消息：气泡里渲染文件卡片（文件名 + 图标 + 大小），点击打开/下载。
          // 模型侧标注由 ChatApi 拼接，气泡只显示文件卡片 + 用户配的字。
          if (message.fileUrl != null && message.fileUrl!.isNotEmpty)
            _avatarRow(
              _buildFileBlock(context, theme, bgColor, fgColor, shadow),
              top: message.content.trim().isEmpty ? 0 : 2,
            ),
          // 遍历块：普通块按空行拆气泡，代码块整块渲染
          for (var bi = 0; bi < blocks.length; bi++)
            ..._buildBlock(
              context,
              theme,
              blocks[bi],
              isMe: isMe,
              markdown: !isMe,
              bgColor: bgColor,
              fgColor: fgColor,
              radius: radius,
              tail: tail,
              shadow: shadow,
              first: bi == 0,
              last: bi == blocks.length - 1,
            ),
          // 网页搜索气泡（v0.2.117）：搜索中显示"努力搜索中"动画；
          // 搜索完成/没完成气泡保留在对话流不消失，点开显示搜到的网站列表。
          if (message.searching || message.searchDone)
            _avatarRow(
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SearchBubble(
                  searching: message.searching,
                  done: message.searchDone,
                  results: message.searchResults,
                  bgColor: bgColor,
                  fgColor: fgColor,
                  shadow: shadow,
                ),
              ),
              top: 8,
            ),
          if (!isMe && message.runtimeStatus == 'failed')
            Padding(
              padding: _avatarSideInset(),
              child: Padding(
                padding: const EdgeInsets.only(top: 5, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.circle_alert,
                      size: 13,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '回复中断',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.error,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 时间戳：气泡外下方小字，颜色淡，不抢正文。
          // 流式输出中（消息没发完）不显示，发完才出现。
          // TTS 入口已收敛到 assistant 文字长按菜单，不再占用元信息行。
          if (!streaming && showTimestamp)
            Padding(
              padding: _avatarSideInset(),
              child: Padding(
                padding: const EdgeInsets.only(top: 5, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timestamp,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // token 用量（命中率）：开关开 + assistant 消息有 usage 时，时间戳下方小字
          // 格式照 RikkaHub ChatMessageNerdLine：命中率 · Input (cached) · Output
          if (!streaming && showTokenUsage && message.usage != null)
            Padding(
              padding: _avatarSideInset(),
              child: Padding(
                padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                child: _usageLine(message.usage!, theme),
              ),
            ),
        ],
      ),
    );
  }

  /// 图片发送中/发送失败占位气泡：灰调低调卡片（圆角 20 + 柔阴影，复用气泡配色），
  /// 内含本地缩略图 + 状态文字；发送中显示加载圈，失败压暗 + 点击弹重试/删除。
  Widget _buildPendingImageBubble(BuildContext context, ThemeData theme) {
    final sending = message.imageSendStatus == ImageSendStatus.sending;
    final timestamp = formatMessageTime(message.time, prevTime);
    final size = MediaQuery.of(context).size;
    final thumbW = size.width * 0.6;
    final thumbH = thumbW * 0.75;
    final bytes = message.imagePreviewBytes;
    final previews = message.imagePreviewBytesList;
    final states = message.imageItemStates;
    final statusText = sending
        ? '正在发送图片…'
        : (previews.isNotEmpty && !states.every((s) => s == 2))
        ? '部分图片没发出去，点按重试'
        : '图片没发出去，点按重试';
    final statusColor = sending
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;

    // 单张缩略图（多选批量共用的子项）：发送中加载圈 / 成功小勾 / 失败压暗云断图标
    Widget thumbItem(Uint8List b, int state) {
      final itemDone = state == 1;
      final itemFailed = state == 2;
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.memory(b, width: 88, height: 88, fit: BoxFit.cover),
            if (itemFailed)
              Positioned.fill(
                child: Container(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                ),
              ),
            if (itemDone)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    LucideIcons.check,
                    size: 12,
                    color: theme.colorScheme.primary,
                  ),
                ),
              )
            else if (itemFailed)
              Icon(
                LucideIcons.cloud_off,
                size: 24,
                color: theme.colorScheme.error,
              )
            else
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
          ],
        ),
      );
    }

    final bubble = GestureDetector(
      // 失败态：点气泡（或长按）弹重试/删除菜单；发送中不响应
      onTap: sending ? null : onImageSendTap,
      onLongPress: sending ? null : onImageSendTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: context.fieldColor,
          boxShadow: [context.cardShadow],
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 多选发图：横排缩略图（可滚动），逐张叠状态（发送中/成功/失败）
            if (previews.isNotEmpty)
              SizedBox(
                height: 88,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: previews.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (_, i) =>
                      thumbItem(previews[i], i < states.length ? states[i] : 0),
                ),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (bytes != null)
                      Image.memory(
                        bytes,
                        width: thumbW,
                        height: thumbH,
                        fit: BoxFit.cover,
                      )
                    else
                      Container(
                        width: thumbW,
                        height: thumbH,
                        color: context.fieldColor,
                      ),
                    if (!sending)
                      Positioned.fill(
                        child: Container(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.22,
                          ),
                        ),
                      ),
                    if (sending)
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    else
                      Icon(
                        LucideIcons.cloud_off,
                        size: 30,
                        color: theme.colorScheme.error,
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Text(
                statusText,
                style: TextStyle(fontSize: 12, color: statusColor, height: 1.2),
              ),
            ),
            // 附带文字照常显示，跟真实图片消息结构一致
            if (message.content.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  message.content,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _avatarRow(bubble),
          // 时间戳：气泡外下方小字，跟普通消息一致
          if (showTimestamp)
            Padding(
              padding: _avatarSideInset(),
              child: Padding(
                padding: const EdgeInsets.only(top: 5, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timestamp,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 文件发送中/失败占位：与最终文件卡片同结构（图标+文件名+大小），
  /// 右侧状态（加载圈/云断），失败点卡片重试/删除。
  Widget _buildPendingFileBubble(BuildContext context, ThemeData theme) {
    final sending = message.fileSendStatus == FileSendStatus.sending;
    final timestamp = formatMessageTime(message.time, prevTime);
    final name = message.fileName?.isNotEmpty == true
        ? message.fileName!
        : '文件';
    final sizeText = _formatFileSize(message.fileSize);
    final statusColor = sending
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;

    final card = GestureDetector(
      onTap: sending ? null : onFileSendTap,
      onLongPress: sending ? null : onFileSendTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 292),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: context.fieldColor,
          boxShadow: [context.cardShadow],
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _fileIconFor(message.fileType),
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sizeText,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (sending)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    LucideIcons.cloud_off,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                sending ? '正在发送文件…' : '文件没发出去，点按重试',
                style: TextStyle(fontSize: 12, color: statusColor, height: 1.2),
              ),
            ),
            // 配字照常显示；空配字兜底占位 '[文件]' 不显示
            if (message.content.trim().isNotEmpty &&
                message.content.trim() != '[文件]')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  message.content,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _avatarRow(card),
          if (showTimestamp)
            Padding(
              padding: _avatarSideInset(),
              child: Padding(
                padding: const EdgeInsets.only(top: 5, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      timestamp,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 段落气泡顶部间距：首段 2，后续段落 10（段间分隔）。
  static double _paragraphTopMargin({
    required bool first,
    required bool isFirstPara,
  }) {
    return first && isFirstPara ? 2 : 10;
  }

  /// 块气泡（代码块）顶部间距：首块 2，后续 10。
  static double _blockTopMargin({required bool first}) {
    return first ? 2 : 10;
  }

  /// 气泡行配头像：AI 助手头像在左、用户头像在右，顶部对齐气泡上缘。
  /// 气泡自带段落间距（首段 2、后续 10），头像同步垫同样 top 间距，
  /// 保证每段头像都和该段气泡上端对齐（v0.2.97 修：后续段落头像不再偏上）。
  /// 子组件用 Flexible 收窄：代码块 0.86 屏宽 + 头像在窄屏不会溢出
  /// （实际宽度和旧版外层 Row(头像+气泡) 一致）。
  Widget _avatarRow(Widget child, {double top = 0}) {
    final avatar = Padding(
      padding: EdgeInsets.only(top: top),
      child: _AvatarView(isMe: isMe),
    );
    final failedIcon = message.sendFailed && isMe
        ? Padding(
            padding: EdgeInsets.only(top: top),
            child: Builder(
              builder: (context) => IconButton(
                onPressed: onSendFailedTap,
                tooltip: '重新编辑',
                icon: Icon(
                  LucideIcons.circle_alert,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
          )
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: isMe
          ? [
              if (failedIcon != null) ...[failedIcon, const SizedBox(width: 4)],
              Flexible(child: child),
              const SizedBox(width: 6),
              avatar,
            ]
          : [avatar, const SizedBox(width: 6), Flexible(child: child)],
    );
  }

  /// 元信息行（时间戳/用量/停顿点）沿头像侧缩进，和正文气泡左/右缘对齐，
  /// 不压到头像正下方。
  EdgeInsets _avatarSideInset() => EdgeInsets.only(
    left: isMe ? 0 : _avatarInset,
    right: isMe ? _avatarInset : 0,
  );

  /// activity 消息卡片：对话流居中、胶囊小气泡、字号小一号（12）、
  /// 颜色走 process 弱层次 + onSurfaceVariant 次级文字，
  /// 与记忆面板次级文字同一语义色），下方带时间戳，深色模式自动适配。
  /// 聊天页 / 只读视图 / 日历共用此渲染。
  static Widget activityCard(
    ThemeData theme,
    ChatMessage message,
    DateTime? prevTime, {
    bool showTimestamp = true,
  }) {
    final colors = theme.extension<AppSemanticColors>();
    final timestamp = formatMessageTime(message.time, prevTime);
    return Align(
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 236),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: colors?.process ?? theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              message.content,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          if (showTimestamp) const SizedBox(height: 4),
          if (showTimestamp)
            Text(
              timestamp,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.outline,
                height: 1.2,
              ),
            ),
        ],
      ),
    );
  }

  /// "AI 助手在忙…"占位（v0.2.114）：8816 执行 shell 期间显示，居中低调小气泡，
  /// 样式照 activity 卡片（小字、灰色、不抢眼），不带时间戳，不暴露任何命令内容。
  /// [label] busy 占位文案（v0.2.118：可带 shell 轮次数字，如"AI 助手在忙… 2"）
  /// [alignment] 对齐方式（v0.2.169）：默认居中（列表末尾占位），
  /// 嵌进回复时间线时传 Alignment.centerLeft 与思考气泡左缘对齐。
  static Widget busyCard(
    ThemeData theme, {
    String label = '正在处理…',
    AlignmentGeometry alignment = Alignment.center,
  }) {
    final colors = theme.extension<AppSemanticColors>();
    return Align(
      alignment: alignment,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 236),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: colors?.process ?? theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11.5,
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  /// "✓ 搞定了！"工具完成标记（v0.2.168）：AI 助手工具执行完成后 busy 占位
  /// 变成这条固定记录，永久保留在对话流（落盘，重启后仍在）。
  /// 样式与 busyCard 完全一致（居中低调小气泡，不带时间戳）。
  static Widget toolDoneCard(
    ThemeData theme, {
    String? label,
    AlignmentGeometry alignment = Alignment.center,
  }) {
    return busyCard(
      theme,
      label: chatToolDoneDisplayLabel(label),
      alignment: alignment,
    );
  }

  /// 把段落文本里的链接渲染成可点击 span：
  /// - markdown 链接 [文字](url)：只显示文字（主题色下划线），不显示裸地址，点开 url
  /// - 裸 URL https://...：显示 URL（主题色下划线）可点击
  /// 其余文本原样。段落里没有链接时返回单 span（行为不变）。
  static List<InlineSpan> _linkify(String text, ThemeData theme) {
    final mdRe = RegExp(r'\[([^\]]+)\]\((https?://[^)\s]+)\)');
    final urlRe = RegExp(r'https?://[^\s<>"()\[\]]+');
    final spans = <InlineSpan>[];
    var pos = 0;
    while (pos < text.length) {
      final rest = text.substring(pos);
      final md = mdRe.firstMatch(rest);
      final url = urlRe.firstMatch(rest);
      // markdown 链接优先（[文字](url) 里也含裸 url，取更靠前的那个）
      final useMd = md != null && (url == null || md.start <= url.start);
      if (!useMd && url == null) break;
      if (useMd) {
        final link = md.group(2) ?? '';
        final label = (md.group(1) ?? '').trim();
        if (md.start > 0) {
          spans.add(TextSpan(text: rest.substring(0, md.start)));
        }
        spans.add(
          TextSpan(
            text: label.isEmpty ? link : label,
            style: TextStyle(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary,
            ),
            recognizer: TapGestureRecognizer()..onTap = () => _openUrl(link),
          ),
        );
        pos += md.end;
      } else {
        final link = url!.group(0) ?? '';
        if (url.start > 0) {
          spans.add(TextSpan(text: rest.substring(0, url.start)));
        }
        spans.add(
          TextSpan(
            text: link,
            style: TextStyle(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary,
            ),
            recognizer: TapGestureRecognizer()..onTap = () => _openUrl(link),
          ),
        );
        pos += url.end;
      }
    }
    if (pos < text.length) {
      spans.add(TextSpan(text: text.substring(pos)));
    }
    return spans.isEmpty ? [TextSpan(text: text)] : spans;
  }

  /// 打开链接：系统浏览器外部打开，不走 App 内嵌。失败静默不打扰聊天。
  static Future<void> _openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // 打不开静默
    }
  }

  /// 命中率显示行：图标 + 数字紧凑一行（命中率 · Input(+缓存标记) · Output）。
  /// 命中率取整百分比；token 过千用 k 显示（如 1.3k）。
  Widget _usageLine(MessageUsage u, ThemeData theme) {
    final hit = (u.hitRate * 100).round();
    final style = TextStyle(
      fontSize: 11,
      color: theme.colorScheme.outline,
      height: 1.2,
    );
    const iconSize = 11.0;
    final sep = SizedBox(width: 6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          LucideIcons.gauge,
          size: iconSize,
          color: theme.colorScheme.outline,
        ),
        SizedBox(width: 2),
        Text('$hit%', style: style),
        sep,
        Icon(
          LucideIcons.arrow_down_to_line,
          size: iconSize,
          color: theme.colorScheme.outline,
        ),
        SizedBox(width: 2),
        Text(_fmtK(u.promptTokens), style: style),
        // 缓存命中 >0 时 Input 数字后加个小数据库标记（不写英文 cached）
        if (u.cacheHit > 0) ...[
          SizedBox(width: 2),
          Icon(
            LucideIcons.database,
            size: iconSize,
            color: theme.colorScheme.outline,
          ),
        ],
        sep,
        Icon(
          LucideIcons.arrow_up_from_line,
          size: iconSize,
          color: theme.colorScheme.outline,
        ),
        SizedBox(width: 2),
        Text(_fmtK(u.completionTokens), style: style),
      ],
    );
  }

  /// token 数字格式化：<1000 原样显示，否则 x.x k（1277 -> 1.3k，四舍五入 1 位）
  static String _fmtK(int n) {
    if (n < 1000) return '$n';
    return '${(n / 100).round() / 10}k';
  }

  /// 图片块：圆角 20 裁切（跟气泡一致），点击进全屏预览（InteractiveViewer 缩放）。
  Widget _buildImageBlock(BuildContext context, ThemeData theme) {
    return _buildImageBlockFor(
      context,
      theme,
      message.imageUrl!,
      bottom: message.content.trim().isEmpty ? 0 : 10,
    );
  }

  /// 指定 URL 的图片块（单图/多选发图共用）：圆角 20 + 点击全屏预览。
  Widget _buildImageBlockFor(
    BuildContext context,
    ThemeData theme,
    String url, {
    double bottom = 10,
  }) {
    final size = MediaQuery.of(context).size;
    final imageWidth = size.width * 0.64;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: GestureDetector(
        onTap: () {
          // 先收键盘再进全屏预览，返回时输入法不会自己弹出来
          FocusManager.instance.primaryFocus?.unfocus();
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ImagePreviewPage(url: url)));
        },
        onLongPress: () => _showImageActions(context, url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: CachedNetworkImage(
            imageUrl: url,
            width: imageWidth,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(
              width: imageWidth,
              height: imageWidth * 0.75,
              color: context.fieldColor,
              child: const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
              ),
            ),
            errorWidget: (_, _, _) => Container(
              width: imageWidth,
              height: imageWidth * 0.75,
              color: context.fieldColor,
              child: Icon(
                LucideIcons.image_off,
                size: 24,
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 文件消息卡片：图标 + 文件名 + 大小，点击用系统浏览器打开/下载。
  Widget _buildFileBlock(
    BuildContext context,
    ThemeData theme,
    Color bgColor,
    Color fgColor,
    BoxShadow shadow,
  ) {
    final url = message.fileUrl!;
    final name = message.fileName?.isNotEmpty == true
        ? message.fileName!
        : '文件';
    final sizeText = _formatFileSize(message.fileSize);
    final kindText = _fileKindLabel(message.fileType);
    final metaText = sizeText == '未知大小' ? kindText : '$kindText · $sizeText';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openUrl(url),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 292),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [shadow],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: fgColor.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _fileIconFor(message.fileType),
                    size: 20,
                    color: fgColor.withValues(alpha: 0.86),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: fgColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        metaText,
                        style: TextStyle(
                          fontSize: 11,
                          color: fgColor.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  LucideIcons.download,
                  size: 18,
                  color: fgColor.withValues(alpha: 0.72),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 文件类型 → 卡片图标（音频/图片/文档，未知回退通用文件图标）。
  static IconData _fileIconFor(String? type) {
    switch (type) {
      case 'audio':
        return LucideIcons.file_music;
      case 'image':
        return LucideIcons.file_image;
      case 'doc':
        return LucideIcons.file_text;
      default:
        return LucideIcons.file;
    }
  }

  static String _fileKindLabel(String? type) => switch (type) {
    'audio' => '音频',
    'image' => '图片',
    'doc' => '文档',
    _ => '文件',
  };

  static String _formatFileSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '未知大小';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  /// 把消息内容按 ``` 代码块拆成块列表。流式输出中代码块可能没闭合，
  /// 没闭合的 ``` 之后内容按代码块处理（保持等宽深底，观感一致）。
  static List<_ContentBlock> _splitBlocks(String content) {
    final blocks = <_ContentBlock>[];
    final re = RegExp(r'```(\w*)\s*\n?');
    var match = re.firstMatch(content);
    var plainStart = 0;
    while (match != null) {
      // match.start 之前的普通文本
      if (match.start > plainStart) {
        blocks.add(
          _ContentBlock(
            text: content.substring(plainStart, match.start),
            isCode: false,
          ),
        );
      }
      // 找闭合 ```
      final codeStart = match.end;
      final closeIdx = content.indexOf('```', codeStart);
      if (closeIdx < 0) {
        // 没闭合：剩下全当代码（流式输出中）
        blocks.add(
          _ContentBlock(
            text: content.substring(codeStart),
            isCode: true,
            lang: match.group(1) ?? '',
          ),
        );
        return blocks;
      }
      blocks.add(
        _ContentBlock(
          text: content.substring(codeStart, closeIdx),
          isCode: true,
          lang: match.group(1) ?? '',
        ),
      );
      plainStart = closeIdx + 3;
      match = re.firstMatch(content.substring(plainStart));
    }
    if (plainStart < content.length) {
      blocks.add(
        _ContentBlock(text: content.substring(plainStart), isCode: false),
      );
    }
    return blocks;
  }

  /// assistant 消息的自然段拆分（v0.2.160）：
  /// - 普通文本一行一段（Continuum Chat原有"一段一气泡"风格），空行/空白行不产生气泡；
  /// - 列表、表格、引用块按 markdown 块级结构整块收集，不在行间拆散；
  /// - 标题（#）单独收集后向前并入下一段，不单独成气泡；
  /// - 引用块（>）向后并入前一段（没有前段则向前并入下一段），跟随所在段落；
  /// - 围栏代码块已由 _splitBlocks 提前切出，这里只处理非代码段。
  static List<String> _splitAssistantParagraphs(String text) {
    final lines = text.split('\n');
    final raw = <List<String>>[];
    var current = <String>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }
      final indent = line.length - line.trimLeft().length;

      // GFM 表格：表头含 | 且下一行是 |---| 分隔行 → 表头+分隔+后续表格行整块。
      if (_isTableStart(lines, i)) {
        if (current.isNotEmpty) {
          raw.add(current);
          current = <String>[];
        }
        final table = <String>[line];
        i++;
        if (i < lines.length) {
          table.add(lines[i]);
          i++;
        }
        while (i < lines.length) {
          final next = lines[i];
          if (next.trim().isEmpty || !next.contains('|')) break;
          table.add(next);
          i++;
        }
        raw.add(table);
        continue;
      }

      // 列表块：行首（缩进 ≤3）是列表标记 → 连续列表项 + 缩进续行整块。
      if (_isListLine(trimmed) && indent <= 3) {
        if (current.isNotEmpty) {
          raw.add(current);
          current = <String>[];
        }
        final list = <String>[];
        while (i < lines.length) {
          final next = lines[i];
          final nextTrim = next.trim();
          final nextIndent = next.length - next.trimLeft().length;
          if (nextTrim.isEmpty) {
            // 松列表：空行后仍接同级列表项就并入（GFM 松列表），否则列表结束。
            var j = i;
            while (j < lines.length && lines[j].trim().isEmpty) {
              j++;
            }
            if (j < lines.length &&
                _isListLine(lines[j].trim()) &&
                (lines[j].length - lines[j].trimLeft().length) <= 3) {
              while (i < lines.length && lines[i].trim().isEmpty) {
                list.add('');
                i++;
              }
              continue;
            }
            break;
          }
          if ((_isListLine(nextTrim) && nextIndent <= 3) ||
              (nextIndent >= 2 &&
                  !_isHeadingLine(nextTrim) &&
                  !_isQuoteLine(nextTrim))) {
            list.add(next);
            i++;
            continue;
          }
          break;
        }
        raw.add(list);
        continue;
      }

      // 引用块：连续 > 行 + GFM 懒续行（紧跟在引用后的普通文本行）整块。
      if (_isQuoteLine(trimmed)) {
        if (current.isNotEmpty) {
          raw.add(current);
          current = <String>[];
        }
        final quote = <String>[];
        while (i < lines.length) {
          final next = lines[i];
          final nextTrim = next.trim();
          if (nextTrim.isEmpty) break;
          if (_isQuoteLine(nextTrim)) {
            quote.add(next);
            i++;
            continue;
          }
          // 懒续行：不打断引用的普通文本行（非标题/列表/表格开头）。
          if (!_isHeadingLine(nextTrim) &&
              !_isListLine(nextTrim) &&
              !_isTableStart(lines, i)) {
            quote.add(next);
            i++;
            continue;
          }
          break;
        }
        raw.add(quote);
        continue;
      }

      // 标题：单独收集，合并阶段向前并入下一段。
      if (_isHeadingLine(trimmed)) {
        if (current.isNotEmpty) {
          raw.add(current);
          current = <String>[];
        }
        raw.add([line]);
        i++;
        continue;
      }

      // 普通文本行：一段一气泡（Continuum Chat原有风格）。
      if (current.isNotEmpty) {
        raw.add(current);
      }
      current = [line];
      i++;
    }
    if (current.isNotEmpty) {
      raw.add(current);
    }

    // 合并：标题向前并入下一组；引用块向后并入前一组（没有前组则并入下一组）。
    final groups = <List<String>>[];
    i = 0;
    while (i < raw.length) {
      final group = List<String>.from(raw[i]);
      if (_isHeadingOnly(group)) {
        while (i + 1 < raw.length) {
          group.addAll(raw[i + 1]);
          i++;
          if (!_isHeadingOnly(raw[i])) break;
        }
        groups.add(group);
        i++;
        continue;
      }
      if (_isQuoteOnly(group)) {
        if (groups.isNotEmpty) {
          groups[groups.length - 1].addAll(group);
        } else if (i + 1 < raw.length) {
          group.addAll(raw[i + 1]);
          i++;
          groups.add(group);
        } else {
          groups.add(group);
        }
        i++;
        continue;
      }
      groups.add(group);
      i++;
    }

    return [
      for (final g in groups) g.join('\n').trim(),
    ].where((s) => s.trim().isNotEmpty).toList();
  }

  /// ATX 标题行：1-6 个 # 后跟空白或行尾（# 后不带空格也按标题处理）。
  static bool _isHeadingLine(String trimmed) {
    return RegExp(r'^#{1,6}(?:\s|$)').hasMatch(trimmed);
  }

  /// 引用行：> 开头。
  static bool _isQuoteLine(String trimmed) => trimmed.startsWith('>');

  /// 列表项行：-/*/+ 或 1. / 1) 后跟空白。
  static bool _isListLine(String trimmed) {
    return RegExp(r'^(?:[-*+]|\d{1,9}[.)])\s+').hasMatch(trimmed);
  }

  /// 组内全部是标题行（标题只有一段时向前并入下一段）。
  static bool _isHeadingOnly(List<String> group) {
    return group.isNotEmpty && group.every(_isHeadingLine);
  }

  /// 组内全部是引用行（引用块向后并入前一段）。
  static bool _isQuoteOnly(List<String> group) {
    return group.isNotEmpty && group.every(_isQuoteLine);
  }

  /// GFM 表格开头：当前行含 | 且紧跟的下一行是合法的 |---|---| 分隔行。
  static bool _isTableStart(List<String> lines, int i) {
    final line = lines[i].trim();
    if (!line.contains('|') || i + 1 >= lines.length) return false;
    final sep = lines[i + 1].trim();
    final cells = sep
        .split('|')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (cells.isEmpty) return false;
    var hasDash = false;
    for (final cell in cells) {
      final body = cell.replaceAll(':', '');
      if (body.isEmpty || body.replaceAll('-', '').isNotEmpty) return false;
      if (body.contains('-')) hasDash = true;
    }
    return hasDash;
  }

  /// 渲染一个块：assistant 普通块走 markdown（GFM），用户文本按行拆段；
  /// 代码块整块深底等宽高亮。
  List<Widget> _buildBlock(
    BuildContext context,
    ThemeData theme,
    _ContentBlock block, {
    required bool isMe,
    required bool markdown,
    required Color bgColor,
    required Color fgColor,
    required Radius radius,
    required Radius tail,
    required BoxShadow shadow,
    required bool first,
    required bool last,
  }) {
    if (block.isCode) {
      // 代码块：独立文本框（圆角容器 + 顶部工具条[语言/复制] + 内部滚动 +
      // 长代码折叠），参考 RikkaHub HighlightCodeBlock.kt 结构
      return [
        _fadeInRow(
          context,
          _CodeBlockWidget(
            code: block.text,
            lang: block.lang,
            margin: EdgeInsets.only(
              top: _blockTopMargin(first: first),
              bottom: last ? 2 : 10,
            ),
          ),
          top: _blockTopMargin(first: first),
        ),
      ];
    }

    // AI 助手（assistant）消息：按自然段拆成多个气泡（v0.2.160 恢复"一段一气泡"），
    // 每段内 GFM markdown 正常渲染（粗体/斜体/行内代码/链接/列表/引用/标题/表格），
    // 空行不产生气泡。原有 [shell]/[search]/[music]/[tool: xxx] 标记在进气泡前已剥离。
    if (markdown) {
      final paragraphs = _splitAssistantParagraphs(block.text);
      return [
        for (var i = 0; i < paragraphs.length; i++)
          ..._buildMarkdownBubble(
            context,
            theme,
            paragraphs[i],
            isMe: isMe,
            bgColor: bgColor,
            fgColor: fgColor,
            radius: radius,
            tail: tail,
            shadow: shadow,
            first: first && i == 0,
          ),
      ];
    }

    // 用户文本：按行拆段，一段一气泡（行为不变，URL 可点击）
    final paragraphs = block.text
        .split('\n')
        .where((p) => p.trim().isNotEmpty)
        .toList();
    return [
      for (var i = 0; i < paragraphs.length; i++)
        _fadeInRow(
          context,
          Container(
            margin: EdgeInsets.only(
              top: _paragraphTopMargin(first: first, isFirstPara: i == 0),
              bottom: last && i == paragraphs.length - 1 ? 2 : 0,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
            decoration: BoxDecoration(
              color: bgColor,
              boxShadow: [shadow],
              borderRadius: isMe
                  ? BorderRadius.only(
                      topLeft: radius,
                      topRight: tail,
                      bottomLeft: radius,
                      bottomRight: radius,
                    )
                  : BorderRadius.only(
                      topLeft: tail,
                      topRight: radius,
                      bottomLeft: radius,
                      bottomRight: radius,
                    ),
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            child: SelectableText.rich(
              TextSpan(
                style: TextStyle(color: fgColor, fontSize: 15.5, height: 1.5),
                // URL 自动识别渲染成可点击链接（主题色+下划线，点开浏览器）；
                // markdown 链接 [文字](url) 只显示文字不显示裸地址
                children: _linkify(paragraphs[i], theme),
              ),
              contextMenuBuilder: _selectionToolbar,
            ),
          ),
          top: _paragraphTopMargin(first: first, isFirstPara: i == 0),
        ),
    ];
  }

  /// 段落/代码块与头像一起淡入（180ms easeOut + 轻微上移），
  /// 流式输出中段落变化时头像跟着一起进出，不单独跳动。
  Widget _fadeInRow(BuildContext context, Widget child, {required double top}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, value, w) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 5 * (1 - value)),
          child: w,
        ),
      ),
      child: _avatarRow(child, top: top),
    );
  }

  /// 长按文字：自绘中文圆角工具栏（不用系统 AdaptiveTextSelectionToolbar，
  /// 避免英文按钮 + Android 智能操作[ChatGPT/AI搜索/朗读]混进来）。
  /// 按钮：复制选中/全选/复制整条/重新生成/删除。
  Widget _selectionToolbar(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final ttsText = message.content.trim();
    final showTts =
        !isMe &&
        !streaming &&
        TtsConfig.instance.readAloud &&
        ttsText.isNotEmpty;
    if (!showTts) {
      return SelectionToolbar(
        editableTextState: editableTextState,
        onCopyAll: onCopyAll,
        onRegenerate: onRegenerate,
        onEdit: onEdit,
        onDelete: onDelete,
      );
    }
    return ListenableBuilder(
      listenable: TtsPlayer.instance,
      builder: (context, _) {
        final player = TtsPlayer.instance;
        final playingThis = player.playing && player.currentText == ttsText;
        return SelectionToolbar(
          editableTextState: editableTextState,
          onCopyAll: onCopyAll,
          onRegenerate: onRegenerate,
          onEdit: onEdit,
          onDelete: onDelete,
          ttsLabel: playingThis ? '停止播放' : '语音播放',
          onTts: () {
            final messenger = ScaffoldMessenger.maybeOf(context);
            unawaited(_toggleTtsFromToolbar(messenger, ttsText));
          },
        );
      },
    );
  }

  Future<void> _toggleTtsFromToolbar(
    ScaffoldMessengerState? messenger,
    String text,
  ) async {
    final player = TtsPlayer.instance;
    await player.toggle(text);
    final error = player.lastError;
    if (error == null || messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(error, style: const TextStyle(fontSize: 13)),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        ),
      );
  }

  /// assistant 消息单个自然段的 markdown 渲染（v0.2.160）：气泡内按块级节点
  /// （段落/标题/列表/引用/表格/围栏与缩进代码块）自上而下渲染，空段落/空行不产生
  /// 空白气泡。代码块在气泡内仍复用 _CodeBlockWidget（语言标签/复制/折叠/高亮），
  /// 气泡胶囊样式与头像排版不变；一条消息按 _splitAssistantParagraphs 拆成多个自然段，
  /// 每段调用一次本方法渲染成一个气泡。
  List<Widget> _buildMarkdownBubble(
    BuildContext context,
    ThemeData theme,
    String text, {
    required bool isMe,
    required Color bgColor,
    required Color fgColor,
    required Radius radius,
    required Radius tail,
    required BoxShadow shadow,
    required bool first,
  }) {
    List<md.Node> nodes;
    try {
      nodes = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      ).parse(text);
    } catch (_) {
      // 解析异常兜底：整段当普通文本（流式中间态极少数情况会走到）
      nodes = [md.Text(text)];
    }
    final items = <_MdItem>[];
    for (final node in nodes) {
      _collectMdItems(node, items);
    }
    // 只有空白/空段落时整体不渲染，避免空白气泡
    if (items.isEmpty) return const [];

    return [
      _fadeInRow(
        context,
        Container(
          margin: EdgeInsets.only(
            top: _blockTopMargin(first: first),
            bottom: 2,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            boxShadow: [shadow],
            borderRadius: isMe
                ? BorderRadius.only(
                    topLeft: radius,
                    topRight: tail,
                    bottomLeft: radius,
                    bottomRight: radius,
                  )
                : BorderRadius.only(
                    topLeft: tail,
                    topRight: radius,
                    bottomLeft: radius,
                    bottomRight: radius,
                  ),
          ),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                // 块级节点之间的段落间距（替代原来的拆气泡间距）
                if (i > 0) const SizedBox(height: 10),
                if (items[i].isCode)
                  _CodeBlockWidget(
                    code: items[i].code!,
                    lang: items[i].lang,
                    margin: EdgeInsets.zero,
                  )
                else
                  _buildMdItem(context, theme, items[i], fgColor),
              ],
            ],
          ),
        ),
        top: _blockTopMargin(first: first),
      ),
    ];
  }

  /// 块级节点收集：pre 转代码块、空白文本与空段落跳过（不再产生空白气泡），
  /// 其余（段落/标题/列表/引用/表格）按一个块收集进同一个气泡。
  void _collectMdItems(md.Node node, List<_MdItem> out) {
    if (node is md.Element && node.tag == 'pre') {
      md.Element? codeEl;
      for (final child in node.children ?? const <md.Node>[]) {
        if (child is md.Element && child.tag == 'code') {
          codeEl = child;
          break;
        }
      }
      final code = (codeEl?.textContent ?? node.textContent).replaceFirst(
        RegExp(r'\n$'),
        '',
      );
      var lang = '';
      final cls = codeEl?.attributes['class'] ?? '';
      if (cls.startsWith('language-')) {
        lang = cls.substring('language-'.length);
      }
      if (code.isNotEmpty) {
        out.add(_MdItem.code(code, lang));
      }
      return;
    }
    if (node is md.Text) {
      if (node.text.trim().isNotEmpty) {
        out.add(_MdItem.text(node));
      }
      return;
    }
    if (node is md.Element) {
      if (node.tag == 'hr') return;
      // 空段落/空引用等（仅空白）直接跳过：气泡内由块间距撑开，不渲染空行占位
      if (node.textContent.trim().isEmpty) return;
      out.add(_MdItem.text(node));
    }
  }

  /// 渲染单个文本类块（段落/标题/列表/引用/表格）。
  Widget _buildMdItem(
    BuildContext context,
    ThemeData theme,
    _MdItem item,
    Color fgColor,
  ) {
    final node = item.node!;
    final base = TextStyle(color: fgColor, fontSize: 15, height: 1.4);
    if (node is md.Element) {
      switch (node.tag) {
        case 'ul':
        case 'ol':
          return _mdList(node, base, theme, fgColor);
        case 'blockquote':
          return _mdQuote(node, base, theme, fgColor);
        case 'table':
          return _mdTable(node, base, fgColor);
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          final headingSize = switch (node.tag) {
            'h1' => 17.5,
            'h2' => 17.0,
            'h3' => 16.5,
            _ => 16.0,
          };
          return _mdSelectable(
            node.children ?? const <md.Node>[],
            base.copyWith(fontWeight: FontWeight.w700, fontSize: headingSize),
            theme,
            fgColor,
          );
        default:
          return _mdSelectable(
            node.children ?? const <md.Node>[],
            base,
            theme,
            fgColor,
          );
      }
    }
    // 顶层裸文本（解析器一般不会这样给，防御兜底）
    return _mdSelectable([node], base, theme, fgColor);
  }

  /// 可选中文本：保留自绘中文工具栏与「复制整条/重新生成/删除」。
  Widget _mdSelectable(
    List<md.Node> nodes,
    TextStyle base,
    ThemeData theme,
    Color fgColor,
  ) {
    return SelectableText.rich(
      TextSpan(
        style: base,
        children: _mdInlineSpans(nodes, base, theme, fgColor),
      ),
      contextMenuBuilder: _selectionToolbar,
    );
  }

  /// 行内节点 → TextSpan：粗体/斜体/删除线/行内代码/链接递归合成，
  /// 链接样式照旧（主题色 + 下划线，点击外部浏览器打开）。
  List<InlineSpan> _mdInlineSpans(
    List<md.Node> nodes,
    TextStyle base,
    ThemeData theme,
    Color fgColor,
  ) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        spans.add(TextSpan(text: node.text, style: base));
        continue;
      }
      if (node is! md.Element) continue;
      if (node.tag == 'br') {
        spans.add(TextSpan(text: '\n', style: base));
        continue;
      }
      var style = base;
      if (node.tag == 'strong' || node.tag == 'b') {
        style = style.copyWith(fontWeight: FontWeight.w700);
      } else if (node.tag == 'em' || node.tag == 'i') {
        style = style.copyWith(fontStyle: FontStyle.italic);
      } else if (node.tag == 'del' || node.tag == 's') {
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      } else if (node.tag == 'code') {
        style = style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 15) - 1,
          backgroundColor: fgColor.withValues(alpha: 0.10),
        );
      }
      if (node.tag == 'a') {
        final href = node.attributes['href'] ?? '';
        final linkStyle = style.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        );
        final recognizer = TapGestureRecognizer()..onTap = () => _openUrl(href);
        spans.add(
          TextSpan(
            style: linkStyle,
            recognizer: recognizer,
            children: _mdInlineSpans(
              node.children ?? const <md.Node>[],
              style,
              theme,
              fgColor,
            ),
          ),
        );
      } else {
        spans.addAll(
          _mdInlineSpans(
            node.children ?? const <md.Node>[],
            style,
            theme,
            fgColor,
          ),
        );
      }
    }
    return spans;
  }

  /// 有序/无序列表：项目符号低调、支持嵌套列表，整块一个气泡。
  Widget _mdList(
    md.Element list,
    TextStyle base,
    ThemeData theme,
    Color fgColor,
  ) {
    final ordered = list.tag == 'ol';
    final items = <md.Element>[];
    for (final child in list.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      final hasText = child.textContent.trim().isNotEmpty;
      final hasNested = (child.children ?? const <md.Node>[]).any(
        (c) => c is md.Element && (c.tag == 'ul' || c.tag == 'ol'),
      );
      if (hasText || hasNested) items.add(child);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          _mdListItem(
            items[i],
            marker: ordered ? '${i + 1}.' : '•',
            base: base,
            theme: theme,
            fgColor: fgColor,
          ),
      ],
    );
  }

  Widget _mdListItem(
    md.Element li, {
    required String marker,
    required TextStyle base,
    required ThemeData theme,
    required Color fgColor,
  }) {
    final inline = <md.Node>[];
    final nested = <Widget>[];
    for (final child in li.children ?? const <md.Node>[]) {
      if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
        nested.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 16),
            child: _mdList(child, base, theme, fgColor),
          ),
        );
      } else {
        inline.add(child);
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(
              marker,
              style: base.copyWith(color: fgColor.withValues(alpha: 0.55)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (inline.isNotEmpty)
                  _mdSelectable(inline, base, theme, fgColor),
                ...nested,
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 引用块：只保留轻量左缘线与缩进，不再在消息气泡里再套一层卡片。
  Widget _mdQuote(
    md.Element quote,
    TextStyle base,
    ThemeData theme,
    Color fgColor,
  ) {
    final quoteBase = base.copyWith(color: fgColor.withValues(alpha: 0.82));
    final children = <Widget>[];
    for (final child in quote.children ?? const <md.Node>[]) {
      if (child is md.Text && child.text.trim().isEmpty) continue;
      if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
        children.add(_mdList(child, quoteBase, theme, fgColor));
      } else if (child is md.Element) {
        children.add(
          _mdSelectable(
            child.children ?? const <md.Node>[],
            quoteBase,
            theme,
            fgColor,
          ),
        );
      } else {
        children.add(_mdSelectable([child], quoteBase, theme, fgColor));
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 2, 4, 2),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.38),
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// GFM 表格降级为等宽对齐文本行（轻量可读，不做真表格渲染）。
  Widget _mdTable(md.Element table, TextStyle base, Color fgColor) {
    final rows = <String>[];
    for (final tr in table.children ?? const <md.Node>[]) {
      if (tr is! md.Element || tr.tag != 'tr') continue;
      final cells = <String>[];
      for (final cell in tr.children ?? const <md.Node>[]) {
        if (cell is md.Element && (cell.tag == 'th' || cell.tag == 'td')) {
          cells.add(cell.textContent.trim());
        }
      }
      if (cells.isNotEmpty) rows.add(cells.join('  '));
    }
    return SelectableText.rich(
      TextSpan(
        style: base.copyWith(
          fontFamily: 'monospace',
          fontSize: 13,
          color: fgColor,
        ),
        children: [TextSpan(text: rows.join('\n'))],
      ),
      contextMenuBuilder: _selectionToolbar,
    );
  }

  /// 轻量语法高亮：字符串 / 注释 / 关键字 / 数字 / 函数名，其余默认色。
  /// 不做完整语言解析（够读就行，别糊成一团），流式输出中也能用。
  /// 静态方法：代码块组件（_CodeBlockWidget）折叠重高亮时也调用。
  static List<TextSpan> highlightCode(String code) {
    final spans = <TextSpan>[];
    final baseStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.5,
      color: AppCodePalette.text,
    );
    // 颜色：代码块底色固定深色画板（AppCodePalette，集中定义在主题文件）
    const kwColor = AppCodePalette.keyword; // 关键字紫
    const strColor = AppCodePalette.string; // 字符串绿
    const comColor = AppCodePalette.comment; // 注释灰
    const numColor = AppCodePalette.number; // 数字橙
    const fnColor = AppCodePalette.function; // 函数蓝

    // 组合正则：字符串 / 注释 / 关键字 / 数字 / 函数名
    final keywordRe = RegExp(
      r'^(?:class|def|function|return|import|from|export|const|let|var|if|else|elif|for|while|switch|case|break|continue|new|try|catch|finally|throw|async|await|yield|public|private|protected|static|void|int|float|double|bool|string|char|true|false|null|None|True|False|print|echo|require|using|namespace|interface|extends|implements|override|final|in|of|is|as|this|self|super)$',
    );
    final re = RegExp(
      r'''("(?:[^"\\]|\\\\.)*"|'(?:[^'\\]|\\\\.)*'|//[^\n]*|/\*[\s\S]*?\*/|\b(?:class|def|function|return|import|from|export|const|let|var|if|else|elif|for|while|switch|case|break|continue|new|try|catch|finally|throw|async|await|yield|public|private|protected|static|void|int|float|double|bool|string|char|true|false|null|None|True|False|print|echo|require|using|namespace|interface|extends|implements|override|final|in|of|is|as|this|self|super)\b|\b\d+\.?\d*\b|\b[A-Za-z_][A-Za-z0-9_]*(?=\())''',
    );
    var pos = 0;
    for (final m in re.allMatches(code)) {
      if (m.start > pos) {
        spans.add(
          TextSpan(text: code.substring(pos, m.start), style: baseStyle),
        );
      }
      final tok = m.group(0)!;
      Color? color;
      if (tok.startsWith('//') || tok.startsWith('/*')) {
        color = comColor;
      } else if (tok.startsWith('"') || tok.startsWith("'")) {
        color = strColor;
      } else if (RegExp(r'^\d').hasMatch(tok)) {
        color = numColor;
      } else if (!keywordRe.hasMatch(tok) &&
          RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(tok)) {
        color = fnColor;
      } else {
        color = kwColor;
      }
      spans.add(
        TextSpan(
          text: tok,
          style: baseStyle.copyWith(color: color, fontWeight: FontWeight.w500),
        ),
      );
      pos = m.end;
    }
    if (pos < code.length) {
      spans.add(TextSpan(text: code.substring(pos), style: baseStyle));
    }
    return spans;
  }

  /// 圆润浮动提示（SnackBar 圆角 + 平滑弹出）
  void _showToast(BuildContext context, String msg) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onInverseSurface,
            ),
          ),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          // 圆润胶囊 + 平滑出现（默认动画就是 easeOut 上浮，足够自然）
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          elevation: 0,
        ),
      );
  }

  Future<void> _showImageActions(BuildContext context, String url) async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
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
            ListTile(
              leading: Icon(
                LucideIcons.download,
                size: 22,
                color: theme.colorScheme.primary,
              ),
              title: const Text('保存到相册', style: TextStyle(fontSize: 15)),
              onTap: () {
                Navigator.pop(ctx);
                _saveImageToGallery(context, url);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImageToGallery(BuildContext context, String url) async {
    _showToast(context, '正在保存…');
    try {
      final ok = await GallerySaver.saveNetworkImage(url);
      if (!context.mounted) return;
      _showToast(context, ok ? '已保存到相册' : '保存失败');
    } on PlatformException catch (e) {
      if (!context.mounted) return;
      _showToast(context, e.message ?? '保存失败');
    } catch (_) {
      if (!context.mounted) return;
      _showToast(context, '保存失败');
    }
  }
}

/// 独立代码块文本框：圆角容器 + 顶部工具条（语言标签 + 复制/下载）+ 代码区
/// 内部滚动（横向超宽可滑、纵向超长折叠），参考 RikkaHub HighlightCodeBlock.kt。
class _CodeBlockWidget extends StatefulWidget {
  final String code;
  final String lang;
  final EdgeInsetsGeometry margin;

  const _CodeBlockWidget({
    required this.code,
    required this.lang,
    required this.margin,
  });

  @override
  State<_CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<_CodeBlockWidget> {
  // 折叠阈值：超过 12 行折叠，点工具条右侧按钮展开/收起（RikkaHub 是 10 行）
  static const int _collapseLines = 12;
  bool _expanded = false;

  List<String> get _visualLines {
    final code = widget.code.endsWith('\n')
        ? widget.code.substring(0, widget.code.length - 1)
        : widget.code;
    return code.split('\n');
  }

  bool get _isLong => _visualLines.length > _collapseLines;

  @override
  Widget build(BuildContext context) {
    // 深色代码底（亮暗统一深色，参考 RikkaHub surfaceContainer 思路但保持代码区深底）
    const codeBg = AppCodePalette.bg;
    final borderColor = AppCodePalette.overlay.withValues(alpha: 0.08);

    // 显示代码：长代码折叠时只显示前 _collapseLines 行（高亮按显示内容重算）
    final lines = _visualLines;
    final displayCode = _expanded || !_isLong
        ? lines.join('\n')
        : lines.take(_collapseLines).join('\n');
    final displayHighlighted = MessageBubble.highlightCode(displayCode);
    final langLabel = widget.lang.trim().isEmpty ? '代码' : widget.lang.trim();

    return Container(
      margin: widget.margin,
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.86,
      ),
      decoration: BoxDecoration(
        color: codeBg,
        border: Border.all(color: borderColor),
        boxShadow: [context.cardShadow],
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 工具条：语言标签（左）+ 折叠/复制/下载（右），参考 RikkaHub
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
            decoration: BoxDecoration(
              color: AppCodePalette.overlay.withValues(alpha: 0.04),
              border: Border(
                bottom: BorderSide(
                  color: AppCodePalette.overlay.withValues(alpha: 0.06),
                ),
              ),
            ),
            child: Row(
              children: [
                // 语言标签
                Text(
                  langLabel,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppCodePalette.overlay.withValues(alpha: 0.45),
                    letterSpacing: 0.3,
                  ),
                ),
                const Spacer(),
                // 折叠按钮（仅长代码显示）
                if (_isLong)
                  _CodeToolBtn(
                    icon: _expanded
                        ? LucideIcons.chevrons_down_up
                        : LucideIcons.chevrons_up_down,
                    tooltip: _expanded ? '收起' : '展开',
                    onTap: () => setState(() => _expanded = !_expanded),
                  ),
                // 复制
                _CodeToolBtn(
                  icon: LucideIcons.copy,
                  tooltip: '复制代码',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.code));
                    _showToast(context, '代码已复制');
                  },
                ),
              ],
            ),
          ),
          // 代码区：横向超宽可滑，纵向超高折叠（不撑全屏）
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                      color: AppCodePalette.text,
                    ),
                    children: displayHighlighted,
                  ),
                ),
              ),
            ),
          ),
          // 折叠提示条：长代码且未展开时显示"共 N 行"
          if (_isLong && !_expanded)
            InkWell(
              onTap: () => setState(() => _expanded = true),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: AppCodePalette.overlay.withValues(alpha: 0.03),
                ),
                child: Text(
                  '还有 ${lines.length - _collapseLines} 行 · 展开',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppCodePalette.overlay.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 圆润浮动提示（SnackBar 圆角 + 平滑弹出）
  void _showToast(BuildContext context, String msg) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onInverseSurface,
            ),
          ),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          // 圆润胶囊 + 平滑出现（默认动画就是 easeOut 上浮，足够自然）
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          elevation: 0,
        ),
      );
  }
}

/// 代码块工具条小图标按钮（无字、圆润、克制）
class _CodeToolBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CodeToolBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 15,
            color: AppCodePalette.overlay.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

/// 内容块：普通文本 或 代码块
class _ContentBlock {
  final String text;
  final bool isCode;
  final String lang;

  _ContentBlock({required this.text, required this.isCode, this.lang = ''});
}

/// markdown 块级单元：文本类（段落/标题/列表/引用/表格）或代码类（缩进代码块）。
class _MdItem {
  final md.Node? node;
  final String? code;
  final String lang;
  final bool isCode;

  const _MdItem.text(this.node) : code = null, lang = '', isCode = false;

  const _MdItem.code(this.code, this.lang) : node = null, isCode = true;
}

/// 消息头像：AI 助手（assistant）在左、用户（user）在右；用户头像加主色细环区分。
/// 数据源 ProfileManager（服务器 avatars）：URL 有就网络加载（失败回退发光猫），
/// 没有就用本地打包发光猫秒显。上传换图后 URL 变，ListenableBuilder 自动刷新。
/// v0.2.96 起每个段落气泡各配一个头像（含图片/代码块气泡），思考气泡无头像。
class _AvatarView extends StatelessWidget {
  final bool isMe;

  const _AvatarView({required this.isMe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = 32.0;
    return ListenableBuilder(
      listenable: ProfileManager.instance,
      builder: (context, _) {
        final mgr = ProfileManager.instance;
        final url = isMe ? mgr.meAvatar : mgr.youAvatar;
        final fallback = Image.asset(
          'assets/icon-continuum.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        );
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isMe
                  ? theme.colorScheme.primary.withValues(alpha: 0.5)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
              width: 1.2,
            ),
          ),
          child: ClipOval(
            child: url.isEmpty
                ? fallback
                : CachedNetworkImage(
                    imageUrl: url,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    placeholder: (_, _) => const SizedBox.shrink(),
                    errorWidget: (_, _, _) => fallback,
                  ),
          ),
        );
      },
    );
  }
}

/// 图片 OCR 是辅助信息：默认只露一个低权重入口，点开才看识别全文。
class _OcrCaption extends StatefulWidget {
  final String text;
  const _OcrCaption({required this.text});

  @override
  State<_OcrCaption> createState() => _OcrCaptionState();
}

class _OcrCaptionState extends State<_OcrCaption> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Semantics(
        button: true,
        expanded: _expanded,
        label: _expanded ? '收起图片文字' : '查看图片文字',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.scan_text,
                        size: 13,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '识别到图片文字',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _expanded
                            ? LucideIcons.chevron_up
                            : LucideIcons.chevron_down,
                        size: 13,
                        color: theme.colorScheme.outline,
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _expanded
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(19, 6, 4, 2),
                            child: SelectableText(
                              widget.text,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
