import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/history_migration_api.dart';
import '../services/history_migration_repository.dart';
import '../services/server_config.dart';
import '../widgets/setting_card.dart';

class HistoryMigrationPreviewPage extends StatefulWidget {
  const HistoryMigrationPreviewPage({super.key});

  @override
  State<HistoryMigrationPreviewPage> createState() =>
      _HistoryMigrationPreviewPageState();
}

class _HistoryMigrationPreviewPageState
    extends State<HistoryMigrationPreviewPage> {
  final HistoryMigrationRepository _repository =
      const HistoryMigrationRepository();
  bool _running = false;
  bool _canImport = false;
  bool _imported = false;
  String? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreState();
  }

  Future<void> _restoreState() async {
    final state = await _repository.loadState();
    if (!mounted || state == null) return;
    final preview = state['preview'];
    final status = state['status']?.toString();
    final report = await _repository.readableReport();
    if (!mounted) return;
    setState(() {
      _report = report == '尚无历史聊天迁移报告' ? null : report;
      _imported = status == 'complete';
      _canImport =
          !_imported &&
          status == 'previewed' &&
          preview is Map &&
          preview['can_import'] == true;
    });
  }

  Future<void> _preview() async {
    if (_running || !ServerConfig.isCandidateRuntime) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await _repository.preview();
      final report = await _repository.readableReport();
      if (!mounted) return;
      final state = await _repository.loadState();
      final preview = state?['preview'];
      setState(() {
        _report = report;
        _canImport = preview is Map && preview['can_import'] == true;
        _imported = false;
      });
    } on HistoryMigrationException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '预演失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _importHistory() async {
    if (_running || !_canImport || !ServerConfig.isCandidateRuntime) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认正式导入到候选服务器？'),
        content: const Text(
          '只会写入阶段 B 的候选正式聊天库，不会修改线上 8816，也不会删除手机 ChatStore / ArchivedChat。导入完成后仍会保留手机原历史作为回滚源。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await _repository.import();
      final report = await _repository.readableReport();
      if (!mounted) return;
      setState(() {
        _report = report;
        _canImport = false;
        _imported = true;
      });
    } on HistoryMigrationException catch (error) {
      if (!mounted) return;
      setState(() => _error = '正式导入失败：${error.message}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '正式导入失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!ServerConfig.isCandidateRuntime) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史迁移预演'),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          SettingCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.shield_check,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '只读检查，不会正式导入',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '会冻结当前手机 ChatStore / ArchivedChat 快照并发送到候选服务器做预演。手机原历史保留，服务器正式聊天记录不写入。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _running ? null : _preview,
                    icon: _running
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.search_check, size: 18),
                    label: Text(_running ? '正在预演…' : '开始只读预演'),
                  ),
                ),
              ],
            ),
          ),
          if (_report != null) ...[
            const SizedBox(height: 12),
            SettingCard(
              child: SelectableText(
                _report!,
                style: const TextStyle(fontSize: 13, height: 1.55),
              ),
            ),
          ],
          if (_report != null && (_canImport || _imported)) ...[
            const SizedBox(height: 12),
            SettingCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _imported ? '已正式导入候选服务器' : '预演通过，可以正式导入候选服务器',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _imported
                        ? '手机原历史仍保留。下一步由服务器逐项回读核对。'
                        : '正式导入只写候选库；线上 8816 和手机原历史都不动。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (!_imported) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _running ? null : _importHistory,
                        icon: _running
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.database_backup, size: 18),
                        label: Text(_running ? '正在导入…' : '正式导入候选服务器'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            SettingCard(
              child: Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
