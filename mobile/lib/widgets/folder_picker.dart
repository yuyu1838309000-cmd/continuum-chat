import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/history_cutover_reconciler.dart';
import '../services/runtime_history_api.dart';
import '../services/runtime_history_repository.dart';

/// 文件夹选择弹窗（公共，v0.2.161）：
/// 开始新对话「归档到」与归档页多选「移动到」共用，避免两套复制粘贴。
/// 选项 = 未分类 + 各文件夹；[allowCreate] 时末尾加「新建文件夹…」。
/// 返回 (id, name)，id 为 null = 未分类；取消返回 null。
Future<({String? id, String name})?> showFolderPicker(
  BuildContext context, {
  String title = '归档到',
  bool allowCreate = false,
  RuntimeHistoryRepository? repository,
  Future<void> Function()? prepareHistory,
}) async {
  final historyRepository = repository ?? RuntimeHistoryRepository();
  try {
    await (prepareHistory ?? HistoryCutoverCoordinator.instance.ensure)();
    final snapshot = await historyRepository.folders();
    if (!context.mounted) return null;
    var folders = <({String id, String name})>[
      for (final folder in snapshot.items)
        (id: folder.folderId, name: folder.name),
    ];
    String selected = ''; // '' = 未分类

    return await showDialog<({String? id, String name})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final options = <({String id, String name})>[
            (id: '', name: '未分类'),
            ...folders,
          ];
          return AlertDialog(
            title: Text(title),
            contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final o in options)
                    _row(
                      ctx,
                      o.name,
                      selected == o.id,
                      () => setSheetState(() => selected = o.id),
                    ),
                  if (allowCreate)
                    _createRow(ctx, () async {
                      final created = await _createFolder(
                        ctx,
                        historyRepository,
                      );
                      if (!ctx.mounted || created == null) return;
                      folders = [...folders, created];
                      setSheetState(() => selected = created.id);
                    }),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final match = options.firstWhere(
                    (o) => o.id == selected,
                    orElse: () => (id: '', name: '未分类'),
                  );
                  Navigator.of(ctx).pop((
                    id: match.id.isEmpty ? null : match.id,
                    name: match.name,
                  ));
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  } on RuntimeHistoryException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读取文件夹失败：${error.message}')));
    }
    return null;
  } finally {
    if (repository == null) historyRepository.close();
  }
}

/// 选择行：勾选圈 + 名字（与 design-guide 简洁风一致，无多余装饰）。
Widget _row(
  BuildContext context,
  String name,
  bool selected,
  VoidCallback onTap,
) {
  final scheme = Theme.of(context).colorScheme;
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Icon(
            selected ? LucideIcons.circle_check : LucideIcons.circle,
            size: 20,
            color: selected ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(name, style: const TextStyle(fontSize: 15))),
        ],
      ),
    ),
  );
}

/// 「新建文件夹…」行：点开输入名字，建好自动选中。
Widget _createRow(BuildContext context, VoidCallback onTap) {
  final scheme = Theme.of(context).colorScheme;
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Icon(LucideIcons.folder_plus, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '新建文件夹…',
              style: TextStyle(fontSize: 15, color: scheme.primary),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 新建文件夹弹窗：名字非空才写 Runtime，成功后自动选中。
Future<({String id, String name})?> _createFolder(
  BuildContext context,
  RuntimeHistoryRepository repository,
) async {
  final ctrl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新建文件夹'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: 20,
        decoration: const InputDecoration(hintText: '文件夹名字'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty || !context.mounted) return null;
  try {
    final folder = await repository.createFolder(name);
    return (id: folder.folderId, name: folder.name);
  } on RuntimeHistoryException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败：${error.message}')));
    }
    return null;
  }
}
