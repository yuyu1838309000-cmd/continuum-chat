import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ChatPage delegates generation lifecycle to RuntimeController', () async {
    final source = await File('lib/pages/chat_page.dart').readAsString();

    expect(source, isNot(contains('ChatApi.cancelActiveSend()')));
    expect(source, isNot(contains('ChatApi.send(')));
    expect(source, contains('_runtime.startChat('));
    expect(source, isNot(contains('Future<void> _stopGeneration()')));
    expect(source, contains("ChatComposerRuntimeState.active => '正在回复…'"));
    expect(source, contains("ChatComposerRuntimeState.draining => '回复还在显示…'"));
    final controller = await File(
      'lib/services/chat_runtime_controller.dart',
    ).readAsString();
    expect(
      controller,
      contains('Future<CancelGenerationOutcome> stopActiveGeneration('),
      reason:
          'runtime recovery capability may remain even though chat UI cannot cancel',
    );
    // Phase 7 继续守 ownership：ChatPage 只发 canonical command 意图，
    // 网络命令与 generation replay 由应用级 RuntimeController 持有。
    expect(source, contains('_runtime.startCanonicalEdit('));
    expect(source, contains('_runtime.startCanonicalRegenerate('));
    expect(source, isNot(contains('ChatApi.editRuntimeEvent(')));
    expect(source, isNot(contains('ChatApi.regenerateRuntimeEvent(')));
    expect(source, isNot(contains('_runtime.attachCommandGeneration(')));
    expect(controller, contains('ChatApi.editRuntimeEvent('));
    expect(controller, contains('ChatApi.regenerateRuntimeEvent('));
    expect(controller, contains('attachCommandGeneration('));
    expect(
      controller,
      contains('activeBranch: branch is List ? branch : null'),
    );
    expect(source, isNot(contains('重新生成还差服务器 Runtime 启动命令')));
    expect(source, isNot(contains('编辑重发还差服务器 Runtime 启动命令')));
  });

  test(
    'manual history scrolling owns the viewport until true bottom',
    () async {
      final source = await File('lib/pages/chat_page.dart').readAsString();
      expect(source, contains('bool get _isAtBottomEdge'));
      expect(source, contains('_userViewingHistory = !_isAtBottomEdge'));
      final canAutoStart = source.indexOf('bool _canAutoScroll');
      final canAutoEnd = source.indexOf('void _jumpToBottom', canAutoStart);
      final canAuto = source.substring(canAutoStart, canAutoEnd);
      expect(canAuto, isNot(contains('_userViewingHistory && _isNearBottom')));
    },
  );

  test('expanded live reasoning preserves the reverse-list viewport', () async {
    final source = await File('lib/pages/chat_page.dart').readAsString();
    expect(source, contains('reasoningOnlyGrowth'));
    expect(source, contains('_latestThinkingExpanded(runtimeReply)'));
    expect(source, contains('_preserveExpandedReasoningViewport('));
    final start = source.indexOf('void _preserveExpandedReasoningViewport');
    final end = source.indexOf('void _toggleThinkingExpanded', start);
    final preserveFlow = source.substring(start, end);
    expect(preserveFlow, contains('_userViewingHistory = true'));
    expect(source, contains('_captureThinkingAnchor'));
    expect(source, contains('requireVisible: true'));
    expect(preserveFlow, contains('_thinkingCardExtents[key]'));
    expect(
      preserveFlow,
      contains('_scroll.preserveAnchorOnNextLayout(key, oldExtent)'),
    );
    expect(preserveFlow, isNot(contains('addPostFrameCallback')));
    expect(preserveFlow, isNot(contains('maxScrollExtent - maxExtent')));
  });

  test(
    'process and tool expanders remove geometry animation and anchor viewport',
    () async {
      final source = await File('lib/pages/chat_page.dart').readAsString();
      final processStart = source.indexOf('Widget _buildProcessSectionBubble');
      final processEnd = source.indexOf(
        'Widget _buildProcessSectionBody',
        processStart,
      );
      final processFlow = source.substring(processStart, processEnd);
      expect(processFlow, isNot(contains('AnimatedSize(')));
      expect(processFlow, contains('onTap: () => _toggleProcessSection(key)'));

      final toolStart = source.indexOf('Widget _buildToolProcessStep');
      final toolEnd = source.indexOf('Widget _buildToolPartBody', toolStart);
      final toolFlow = source.substring(toolStart, toolEnd);
      expect(toolFlow, isNot(contains('AnimatedSize(')));
      expect(toolFlow, contains('onTap: () => _toggleToolExpanded(key)'));

      final helperStart = source.indexOf('void _toggleViewportAnchoredSet');
      final helperEnd = source.indexOf(
        'String _processSectionKey',
        helperStart,
      );
      final helperFlow = source.substring(helperStart, helperEnd);
      expect(helperFlow, contains('_userViewingHistory = true'));
      expect(helperFlow, contains('_scroll.preserveAnchorOnNextLayout('));
      expect(source, contains('oldExtent: _processSectionExtents[key]'));
      expect(source, contains('oldExtent: _toolStepExtents[key]'));
      expect(helperFlow, isNot(contains('maxScrollExtent')));
      expect(helperFlow, isNot(contains('jumpTo(')));
      expect(source, contains('_processSectionExtents[key] = extent'));
      expect(source, contains('_toolStepExtents[key] = extent'));
      expect(source, contains('_scroll.reportAnchorExtent(key, extent)'));
    },
  );

  test(
    'tapping live reasoning open anchors the viewport before resize',
    () async {
      final source = await File('lib/pages/chat_page.dart').readAsString();
      final start = source.indexOf('void _toggleThinkingExpanded');
      final end = source.indexOf('void _toggleProcessSection', start);
      final toggleFlow = source.substring(start, end);

      expect(
        toggleFlow,
        contains('final anchorDy = _captureThinkingAnchor(key)'),
      );
      expect(toggleFlow, contains('_thinkingCardExtents[key]'));
      expect(
        toggleFlow,
        contains('_scroll.preserveAnchorOnNextLayout(key, oldExtent)'),
      );
      expect(toggleFlow, contains('_userViewingHistory = true'));
      expect(toggleFlow, isNot(contains('correctPixels(')));
      expect(toggleFlow, isNot(contains('jumpTo(')));
      expect(toggleFlow, isNot(contains('_scheduleThinkingAnchorCorrection')));
      expect(
        toggleFlow.indexOf(
          '_scroll.preserveAnchorOnNextLayout(key, oldExtent)',
        ),
        lessThan(toggleFlow.indexOf('setState(()')),
      );
      expect(
        toggleFlow.indexOf('_userViewingHistory = true'),
        lessThan(toggleFlow.indexOf('setState(()')),
      );
      expect(source, contains('child: _ReportLayoutExtent('));
      expect(source, contains('_scroll.reportAnchorExtent(key, extent)'));
      expect(source, contains('bool applyContentDimensions('));
      expect(source, contains('correctPixels(corrected)'));
      expect(source, isNot(contains('_StableHistoryChildDelegate')));
      expect(source, isNot(contains('_thinkingCorrectionCacheExtent')));
    },
  );

  test(
    'short pending text gets idle fallback without changing pacing formula',
    () async {
      final source = await File('lib/pages/chat_page.dart').readAsString();
      expect(
        source,
        contains(
          'static const Duration _pendingSegmentIdle = Duration(milliseconds: 260)',
        ),
      );
      expect(source, contains('if (_pendingReadyForPause)'));
      expect(source, contains('_freezePendingAsNextSegment();'));
      expect(source, contains('_schedulePendingIdleFlush();'));
      expect(source, contains('Timer(_pendingSegmentIdle, ()'));
      expect(source, contains('_pendingSlot != slot'));
      expect(source, isNot(contains('!identical(_pendingTarget, target)')));
      expect(
        source,
        contains('(800 + nextLen * 30).clamp(800, 3500)'),
        reason: 'keep the existing length-based bubble pacing unchanged',
      );
    },
  );

  test(
    'new chat resolves cancellable archive choice before rollover',
    () async {
      final source = await File('lib/pages/chat_page.dart').readAsString();
      final start = source.indexOf('Future<void> _startNewChat()');
      final end = source.indexOf('Future<({String? id, String name})?>', start);
      final newChatFlow = source.substring(start, end);
      final folderChoice = newChatFlow.indexOf('await _pickArchiveFolder()');
      final cancelled = newChatFlow.indexOf('archiveFolder == null');
      final rollover = newChatFlow.indexOf('ChatApi.rolloverRuntimeEpoch(');
      final archiveWrite = newChatFlow.indexOf(
        'ChatStore.archiveMessagesAndClearCurrent(',
      );
      final clearCurrentCache = newChatFlow.indexOf(
        'await ChatStore.save(const []);',
      );

      expect(folderChoice, greaterThanOrEqualTo(0));
      expect(cancelled, greaterThan(folderChoice));
      expect(rollover, greaterThan(cancelled));
      expect(archiveWrite, -1);
      expect(clearCurrentCache, greaterThan(rollover));
    },
  );

  test('history entry opens the Hub with current runtime messages', () async {
    final source = await File('lib/pages/chat_page.dart').readAsString();
    final start = source.indexOf('Future<void> _openHistory()');
    final end = source.indexOf('Future<void> _openMemory()', start);
    final historyFlow = source.substring(start, end);

    expect(historyFlow, contains('HistoryHubPage(currentMessages: _messages)'));
    expect(historyFlow, contains('_focusMessageAt(index)'));
    expect(historyFlow, isNot(contains('ChatStore.loadArchives()')));
  });
}
