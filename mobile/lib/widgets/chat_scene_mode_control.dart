import 'dart:async';

import 'package:flutter/material.dart';
import 'package:morphnext/morphnext.dart';

import '../services/chat_api.dart';
import '../utils/app_theme.dart';

typedef SceneModeLoader = Future<SceneMode?> Function();
typedef SceneModeSaver = Future<SceneMode?> Function(SceneMode mode);

class ChatSceneModeControl extends StatefulWidget {
  const ChatSceneModeControl({super.key, this.loadMode, this.saveMode});

  final SceneModeLoader? loadMode;
  final SceneModeSaver? saveMode;

  @override
  State<ChatSceneModeControl> createState() => _ChatSceneModeControlState();
}

class _ChatSceneModeControlState extends State<ChatSceneModeControl> {
  SceneMode _mode = SceneMode.unknown;
  bool _saving = false;

  SceneModeLoader get _loadMode => widget.loadMode ?? ChatApi.fetchSceneMode;
  SceneModeSaver get _saveMode => widget.saveMode ?? ChatApi.saveSceneMode;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final loaded = await _loadMode();
    if (!mounted || loaded == null) return;
    setState(() => _mode = loaded);
  }

  String _labelFor(SceneMode mode) => switch (mode) {
    SceneMode.unknown => '未选择',
    SceneMode.online => '线上',
    SceneMode.faceToFace => '面对面',
  };

  Future<void> _openPicker() async {
    if (_saving) return;
    final selected = await showModalBottomSheet<SceneMode>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs,
                0,
                AppSpacing.xs,
                AppSpacing.xs,
              ),
              child: Text(
                '相处模式',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            _SceneModeOption(
              mode: SceneMode.online,
              label: '线上',
              icon: Icons.language_rounded,
              selected: _mode == SceneMode.online,
              onTap: () => Navigator.of(sheetContext).pop(SceneMode.online),
            ),
            _SceneModeOption(
              mode: SceneMode.faceToFace,
              label: '面对面',
              icon: Icons.people_alt_rounded,
              selected: _mode == SceneMode.faceToFace,
              onTap: () => Navigator.of(sheetContext).pop(SceneMode.faceToFace),
            ),
          ],
        ),
      ),
    );
    if (selected == null || selected == _mode || !mounted) return;
    await _changeMode(selected);
  }

  Future<void> _changeMode(SceneMode selected) async {
    final previous = _mode;
    setState(() => _saving = true);
    final saved = await _saveMode(selected);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _mode = saved ?? previous;
    });
    if (saved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('切换失败，请稍后再试'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  IconData _iconFor(SceneMode mode) => switch (mode) {
    SceneMode.unknown => Icons.circle_outlined,
    SceneMode.online => Icons.language_rounded,
    SceneMode.faceToFace => Icons.people_alt_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = _labelFor(_mode);
    final color = _saving || _mode == SceneMode.unknown
        ? colors.onSurfaceVariant
        : colors.primary;
    return IconButton(
      key: const ValueKey('scene-mode-button'),
      tooltip: '相处模式：$label',
      onPressed: _saving ? null : _openPicker,
      style: IconButton.styleFrom(
        foregroundColor: color,
        disabledForegroundColor: colors.onSurfaceVariant,
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: AnimatedMorphIcon(
        icon: _iconFor(_mode),
        size: 24,
        color: color,
        semanticLabel: null,
      ),
    );
  }
}

class _SceneModeOption extends StatelessWidget {
  const _SceneModeOption({
    required this.mode,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final SceneMode mode;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('scene-mode-option-${mode.wireValue}'),
      minTileHeight: 48,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      leading: Icon(icon, size: 20, color: colors.onSurfaceVariant),
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check_rounded, size: 20, color: colors.primary)
          : null,
      onTap: onTap,
    );
  }
}
