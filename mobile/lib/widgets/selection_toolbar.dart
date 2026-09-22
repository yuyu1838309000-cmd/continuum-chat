import 'package:flutter/material.dart';
import '../utils/app_theme.dart';

/// 自绘长按选择工具栏：中文圆角胶囊按钮。
/// 不用系统 AdaptiveTextSelectionToolbar（Android 上会混入英文按钮 + 系统
/// 智能操作[询问ChatGPT/AI搜索/朗读]），全部自己画，干净可控。
/// v0.2.117 抽成公共组件：普通消息气泡（MessageBubble）与思考气泡
/// （ThinkingCard）共用同一套选择/复制体验。
class SelectionToolbar extends StatelessWidget {
  final EditableTextState editableTextState;
  final VoidCallback? onCopyAll;
  final VoidCallback? onRegenerate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final String? ttsLabel;
  final VoidCallback? onTts;

  const SelectionToolbar({
    super.key,
    required this.editableTextState,
    this.onCopyAll,
    this.onRegenerate,
    this.onEdit,
    this.onDelete,
    this.ttsLabel,
    this.onTts,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textEditingValue = editableTextState.textEditingValue;
    final selection = textEditingValue.selection;
    final hasSelection = selection.isValid && !selection.isCollapsed;

    // 锚点（全局坐标）：TextSelectionToolbar 自动处理屏幕边界（放不下翻侧/夹紧）
    final anchors = editableTextState.contextMenuAnchors;

    final buttons = <Widget>[
      // 复制选中（有选中内容才显示）
      if (hasSelection)
        ToolButton(
          label: '复制',
          onTap: () {
            editableTextState.copySelection(SelectionChangedCause.toolbar);
            editableTextState.hideToolbar();
          },
        ),
      // 全选
      ToolButton(
        label: '全选',
        onTap: () {
          editableTextState.selectAll(SelectionChangedCause.toolbar);
        },
      ),
      // 复制整条
      if (onCopyAll != null)
        ToolButton(
          label: '复制整条',
          onTap: () {
            editableTextState.hideToolbar();
            onCopyAll!();
          },
        ),
      // 语音播放（仅 assistant 普通文字，由调用方按需传入）
      if (onTts != null)
        ToolButton(
          label: ttsLabel ?? '语音播放',
          onTap: () {
            editableTextState.hideToolbar();
            onTts!();
          },
        ),
      // 重新生成（仅 AI 消息）
      if (onRegenerate != null)
        ToolButton(
          label: '重新生成',
          onTap: () {
            editableTextState.hideToolbar();
            onRegenerate!();
          },
        ),
      // 编辑重发（仅自己的 user 消息，v0.2.161）
      if (onEdit != null)
        ToolButton(
          label: '编辑重发',
          onTap: () {
            editableTextState.hideToolbar();
            onEdit!();
          },
        ),
      // 删除
      if (onDelete != null)
        ToolButton(
          label: '删除',
          onTap: () {
            editableTextState.hideToolbar();
            onDelete!();
          },
        ),
    ];

    // 用 Flutter 内置 TextSelectionToolbar：自动定位不超屏、放不下自动翻侧，
    // toolbarBuilder 自定义外观（圆角胶囊 + 主题配色，无竖线）
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      toolbarBuilder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            boxShadow: [context.cardShadow],
          ),
          child: child,
        );
      },
      children: buttons,
    );
  }
}

/// [SelectionArea] 版本的思考正文选择工具栏。
///
/// settled 思考使用 Text + SelectionArea，避免 SelectableText/EditableText
/// 在长正文首次展开时承担额外的编辑态布局成本，同时保留选择、复制、全选和
/// 调用方提供的“复制整条”入口。
class SelectionAreaToolbar extends StatelessWidget {
  final SelectableRegionState selectableRegionState;
  final VoidCallback? onCopyAll;

  const SelectionAreaToolbar({
    super.key,
    required this.selectableRegionState,
    this.onCopyAll,
  });

  @override
  Widget build(BuildContext context) {
    final items = selectableRegionState.contextMenuButtonItems;
    ContextMenuButtonItem? itemOfType(ContextMenuButtonType type) {
      for (final item in items) {
        if (item.type == type) return item;
      }
      return null;
    }

    final copy = itemOfType(ContextMenuButtonType.copy);
    final selectAll = itemOfType(ContextMenuButtonType.selectAll);
    final anchors = selectableRegionState.contextMenuAnchors;
    final theme = Theme.of(context);
    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      toolbarBuilder: (context, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            boxShadow: [context.cardShadow],
          ),
          child: child,
        );
      },
      children: [
        if (copy?.onPressed != null)
          ToolButton(label: '复制', onTap: copy!.onPressed!),
        if (selectAll?.onPressed != null)
          ToolButton(label: '全选', onTap: selectAll!.onPressed!),
        if (onCopyAll != null)
          ToolButton(
            label: '复制整条',
            onTap: () {
              selectableRegionState.hideToolbar();
              onCopyAll!();
            },
          ),
      ],
    );
  }
}

/// 工具栏里的单个中文按钮（圆润、字小、无图标）
class ToolButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const ToolButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
