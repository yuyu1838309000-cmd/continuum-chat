import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../widgets/swipe_back.dart';
import '../utils/nickname.dart';
import '../utils/app_theme.dart';
import '../utils/chat_part_timeline.dart';
import '../utils/chat_process_copy.dart';
import '../utils/reasoning_pref.dart';
import '../utils/timestamp_pref.dart';
import '../utils/token_usage.dart';
import '../models/message.dart';
import '../services/chat_api.dart';
import '../services/chat_runtime_controller.dart';
import '../services/chat_store.dart';
import '../services/extension_config_api.dart';
import '../services/runtime_event_client.dart';
import '../services/file_picker_api.dart';
import '../services/image_crop_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_scene_mode_control.dart';
import '../widgets/thinking_card.dart';
import '../widgets/folder_picker.dart';
import 'overview_drawer.dart';
import 'settings_page.dart';
import 'history_hub_page.dart';
import 'search_page.dart';
import 'memory_page.dart';
import 'assistant_hub_page.dart';
import 'together_hub_page.dart';
import 'toolbox_page.dart';
import 'quick_messages_page.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:image_picker/image_picker.dart';
import '../services/server_config.dart';
import '../services/notify_panel.dart';
import '../services/nudge_api.dart';
import 'chat_reply_presentation.dart';

/// 思考气泡左缩进：对齐正文气泡左缘（头像 34 + 头像-气泡间距 6），
/// 思考气泡无头像，缩进后和正文气泡同一条左边缘，视觉成组。
const double _kThinkingInset = 40;

class _TextSegment {
  const _TextSegment(this.text, this.target, this.slot);

  final String text;
  final ChatMessagePart? target;
  final String? slot;
}

enum ChatComposerRuntimeState { active, draining, idle }

class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 148),
        child: Text(
          '我在这儿，慢慢说。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppType.body,
            height: 1.5,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
          ),
        ),
      ),
    );
  }
}

class _ExpandedInputField extends StatefulWidget {
  const _ExpandedInputField({
    required this.initialText,
    required this.onChanged,
  });

  final String initialText;
  final ValueChanged<String> onChanged;

  @override
  State<_ExpandedInputField> createState() => _ExpandedInputFieldState();
}

class _ExpandedInputFieldState extends State<_ExpandedInputField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: true,
      expands: true,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      scrollPadding: const EdgeInsets.only(bottom: 88),
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        hintText: '写点什么…',
        filled: true,
        fillColor: context.fieldColor,
        contentPadding: const EdgeInsets.all(14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class ChatComposerSendButton extends StatelessWidget {
  const ChatComposerSendButton({
    super.key,
    required this.state,
    required this.hasContent,
    required this.busy,
    required this.onSend,
  });

  final ChatComposerRuntimeState state;
  final bool hasContent;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSend =
        state == ChatComposerRuntimeState.idle && hasContent && !busy;
    final highContrast = canSend;
    final background = highContrast
        ? theme.colorScheme.primary
        : context.fieldColor;
    final foreground = highContrast
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.48);
    final tooltip = switch (state) {
      ChatComposerRuntimeState.active => '正在回复…',
      ChatComposerRuntimeState.draining => '回复还在显示…',
      ChatComposerRuntimeState.idle => '发送',
    };
    final onPressed = switch (state) {
      ChatComposerRuntimeState.idle when canSend => onSend,
      ChatComposerRuntimeState.active ||
      ChatComposerRuntimeState.draining ||
      ChatComposerRuntimeState.idle => null,
    };
    final showProgress =
        busy ||
        state == ChatComposerRuntimeState.active ||
        state == ChatComposerRuntimeState.draining;

    return SizedBox.square(
      dimension: 44,
      child: IconButton.filled(
        key: ValueKey('chat-composer-${state.name}'),
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background,
          disabledForegroundColor: foreground,
          minimumSize: const Size(44, 44),
          maximumSize: const Size(44, 44),
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: showProgress
            ? SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: foreground,
                ),
              )
            : const Icon(LucideIcons.arrow_up, size: 19),
      ),
    );
  }
}

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChange);

  ValueChanged<Size> onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _oldSize) return;
    _oldSize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(size));
  }
}

class _ReportLayoutExtent extends SingleChildRenderObjectWidget {
  const _ReportLayoutExtent({required this.onLayout, required super.child});

  final ValueChanged<double> onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ReportLayoutExtentRenderObject(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ReportLayoutExtentRenderObject renderObject,
  ) {
    renderObject.onLayout = onLayout;
  }
}

class _ReportLayoutExtentRenderObject extends RenderProxyBox {
  _ReportLayoutExtentRenderObject(this.onLayout);

  ValueChanged<double> onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout(size.height);
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final List<ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  /// 切后台时输入框有焦点 → 回前台自动补回（输入法保持打开，不重新手点）。
  bool _restoreInputFocusOnResume = false;

  /// 键盘是否真的弹着（viewInsets 判断；避免输入框有焦点但键盘收着时误判）。
  bool _keyboardVisible = false;
  // 发图（12④ 图片消息）：选图附加到输入框（微信式），点发送时上传+OCR+发模型
  final ImagePicker _picker = ImagePicker();
  bool _uploadingImage = false;

  /// 图片发送中/失败占位消息 → 本地图片数据（失败重试用）。
  /// 占位气泡是瞬态（不落盘），发送完成/删除后移除。
  final Map<ChatMessage, _PendingImageData> _pendingImageJobs = {};
  // 待发图片（多选发图）：选图后横排附加在输入框上方，可逐张移除；
  // 发送时整批带着一起发（多张合并成一次模型提交）
  final List<_PendingImageItem> _pendingImages = [];
  // 文件上传（加号按钮）：发送中守卫防重复；失败占位卡片可重试
  bool _uploadingFile = false;
  final Map<ChatMessage, _PendingFileData> _pendingFileJobs = {};
  final _ChatScrollController _scroll = _ChatScrollController();
  double _composerHeight = 0;
  static const double _autoScrollLockThreshold = 100;
  // 距底超过阈值视为用户在看历史，新内容不抢滚动位置。
  bool _userViewingHistory = false;
  bool _userScrollingMessages = false;
  bool _showScrollJumpButtons = false;
  Timer? _scrollJumpButtonsTimer;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _sending = false;
  // 输入框展开：点展开键弹 4/5 屏卡片编辑长文本，保存后收起
  // 全屏右滑拉抽屉：累计向右拖动超过阈值触发，避免聊天滚动误触
  // 跟手抽屉：AnimationController 驱动抽屉偏移（0 关 / 1 开），手势跟手拖动
  late final AnimationController _drawerCtrl;
  static const Duration _drawerAnimationDuration = Duration(milliseconds: 240);
  static const double _drawerWidthFactor = 0.8;
  static const double _drawerMaxWidth = 360;
  static const double _drawerDragActivationDistance = 18;
  static const double _drawerDirectionRatio = 1.2;
  static const double _drawerFlingVelocity = 520;
  static const double _drawerSettleThreshold = 0.5;
  double _dragStartDx = 0;
  double _dragStartDy = 0;
  double _dragStartValue = 0;
  bool _drawerDragAccepted = false;
  bool _drawerDragRejected = false;
  // "正在输入中…"：嵌在标题"AI 助手"下方，收到第一个正文 chunk 隐藏
  bool _typing = false;
  late final AnimationController _typingAnim;
  // 搜索结果定位：点击搜索结果返回下标，滚动到该条并短暂高亮
  int? _focusIndex;
  bool _focusPending = false;
  Timer? _focusTimer;
  // 心跳轮询：AI 助手主动找我的消息，开关关着不轮询
  Timer? _heartbeatTimer;
  static const String _allowProactiveKey = 'allow_proactive';

  // 平滑打字机：流式收到的内容先进 _pending，由定时器匀速吐出，
  // 不受服务端 chunk 大小/间隔影响，观感平滑不生硬
  String _pending = '';
  DateTime? _pendingLastDeltaAt;
  Timer? _pendingIdleTimer;
  int _pendingRevision = 0;
  int _pendingRound = 0;
  ChatMessagePart? _pendingTarget;
  String? _pendingSlot;
  // 流式原始内容（未剥离版）：打字机显示时剥离工具标记，收尾时
  // 从这里提取 [ask]/[calendar_*] 标记走各自链路
  String _rawReply = '';
  // 流式输出中是否处于代码块内（段以 ``` 开头翻转）。代码块内行用短停顿，
  // 避免代码一行一行等 1-3 秒（慢得像卡住）
  bool _inCodeBlock = false;
  Timer? _typeTimer;
  static const Duration _tick = Duration(milliseconds: 20); // 50字/秒
  static const Duration _pendingSegmentIdle = Duration(milliseconds: 260);

  // 丝滑输出：流式内容按空行切段入队，段间停顿 0.5~1s，停顿显示三点
  final List<_TextSegment> _segments = [];
  String _currentSeg = '';
  ChatMessagePart? _currentSegTarget;
  String? _currentSegSlot;
  bool _pausing = false;
  Timer? _pauseTimer;
  // 思考面板展开状态（按消息对象引用 + 轮次）
  final Set<String> _expandedThinking = {};
  final Map<String, GlobalKey> _thinkingAnchorKeys = {};
  final Map<String, double> _thinkingCardExtents = {};
  final Map<String, double> _processSectionExtents = {};
  final Map<String, double> _toolStepExtents = {};
  ChatMessage? _viewportRuntimeReply;
  int _viewportReasoningLength = 0;
  int _viewportContentLength = 0;
  // 工具卡展开状态（按消息对象引用 + part 下标/轮次）
  final Set<String> _expandedTools = {};
  // 过程区段展开状态（按消息对象引用 + 连续区段起始 part 下标）
  final Set<String> _expandedProcessSections = {};
  // 思考显示（v0.2.119 起实时同步）：onReasoning 累积原文到
  // reply.reasoning（落盘用），同时直接同步 _thinkingShown ——
  // DeepSeek 思考什么就显示什么，不再用慢速打字机。
  // v0.2.121：多轮思考后 _thinkingShown 同步当前轮（reasonings.last），
  // 当前轮思考气泡实时跟随，历史轮显示该轮完整内容。
  // v0.2.83 起原为独立打字机匀速吐字，v0.2.111 收起态也直接可见；
  // v0.2.119 去掉打字机与"流结束全贴"机制
  String _thinkingShown = '';
  // 正在流式思考的回复（v0.2.110）：期间该消息的思考气泡跟随 _thinkingShown
  // （v0.2.119 起 _thinkingShown 实时同步），onDone 清标记回全量
  ChatMessage? _thinkingReply;
  // 当前正在流式输出的回复（停顿三点/思考气泡定位用）
  ChatMessage? _activeReply;
  // 流是否已结束（onDone 触发）。结束后打字机继续吐完队列，不一次性 flush
  bool _streamDone = false;
  final ChatReplyPresentation _replyPresentation = ChatReplyPresentation();
  bool get _presentationDraining =>
      _replyPresentation.terminal && _replyPresentation.hasUnrevealedText;

  bool _presentationPendingFor(ChatMessage message) =>
      identical(_replyPresentation.reply, message) &&
      (!_replyPresentation.terminal || _replyPresentation.hasUnrevealedText);
  // v0.2.118：8816 正在执行 shell（busy 事件）。对话流显示"AI 助手在忙…"小气泡
  // （带当前 shell 轮次 _busyRound，round >= 2 时显示数字），
  // 不暴露任何命令/操作内容。v0.2.168：执行完占位不消失，
  // 变成"✓ 搞定了！"永久记录（_insertToolDoneMarker），不再自动清掉。
  // v0.2.169：round > 0 的 busy 属于正在流式的回复，渲染时嵌进该回复内部
  // 时间线（跟在对应思考轮之后）；round == 0 是心跳静默工具，仍走列表末尾占位。
  bool _busy = false;
  int _busyRound = 0;
  // v0.2.153：手机操作中（Termux 桥接 / Nudge 手机工具委托）——8816 推
  // termux_pending / nudge_pending，App 在手机本机执行中，busy 小气泡文案
  // 换成"AI 助手在手机上操作…"
  bool _termuxRunning = false;
  final ChatRuntimeController _runtime = ChatRuntimeController.instance;
  // 快捷消息（v0.2.153）：聊天页闪电入口点开直接发送（缓存一份，拉不到用默认）
  List<String> _quickMessages = const [];

  // 上线问候（可选，保持界面不空）
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScrollChanged);
    _typingAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _drawerCtrl = AnimationController(
      vsync: this,
      duration: _drawerAnimationDuration,
    );
    WidgetsBinding.instance.addObserver(this);
    _runtime.addListener(_onRuntimeChanged);
    _initMessages();
    _startHeartbeatPolling();
    // 服务器为准同步「允许AI 助手主动找我」总开关（审计报告 🟡#3）
    unawaited(_syncAllowProactiveFromServer());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _restoreInputFocusOnResume = _inputFocus.hasFocus && _keyboardVisible;
    } else if (state == AppLifecycleState.resumed &&
        _restoreInputFocusOnResume) {
      _restoreInputFocusOnResume = false;
      _restoreInputFocusAndKeyboard();
    }
  }

  void _restoreInputFocusAndKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inputFocus.requestFocus();
      _showTextInputIfFocused();
      Future<void>.delayed(
        const Duration(milliseconds: 80),
        _showTextInputIfFocused,
      );
      Future<void>.delayed(
        const Duration(milliseconds: 260),
        _showTextInputIfFocused,
      );
    });
  }

  void _showTextInputIfFocused() {
    if (!mounted || !_inputFocus.hasFocus) return;
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  /// GET /status 读 allow_proactive 覆盖本地默认；服务器不可达保持本地值。
  Future<void> _syncAllowProactiveFromServer() async {
    final server = await ChatApi.fetchAllowProactive();
    if (server == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowProactiveKey, server);
  }

  // 键盘弹出：build 里监听 viewInsets，弹起瞬间判断当前位置是否在底部附近，
  // 是则弹起全程每帧跟随滚底（jumpTo 当前 maxScrollExtent），与键盘动画同步，
  // 视觉上是列表被键盘平滑推上去；翻历史（位置在上方）不跟随。
  // didChangeMetrics 回调时 viewInsets 还是旧值 0，读不到键盘高度，废弃该路子。
  bool _keyboardUpBefore = false;
  bool _keyboardFollowScroll = false;

  // 在 build 开头调用：检测键盘弹出/收起，需要时安排跟随滚底
  void _handleKeyboardInset(double viewInset) {
    final keyboardUp = viewInset > 0;
    _keyboardVisible = keyboardUp;
    if (keyboardUp && !_keyboardUpBefore) {
      // Reverse list: minScrollExtent is the newest/bottom edge. Only follow
      // the keyboard while the user is already reading the live tail.
      _keyboardFollowScroll = _scroll.hasClients && _isNearBottom;
    }
    if (keyboardUp && _keyboardFollowScroll && _scroll.hasClients) {
      // 弹起期间每帧跟随当前底部，与键盘动画同步。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.minScrollExtent);
        }
      });
    }
    if (!keyboardUp) {
      _keyboardFollowScroll = false;
    }
    _keyboardUpBefore = keyboardUp;
  }

  // 启动时恢复历史；完全没历史才塞初始问候
  Future<void> _initMessages() async {
    // 启动动画页已并行预加载（ChatStore.cache），直接秒显
    final saved = ChatStore.cache ?? await ChatStore.warmUp();
    if (!mounted) return;
    setState(() {
      // 有历史就恢复，没历史就空白窗口，不再塞开场白（用户定的）
      if (_messages.isEmpty && saved.isNotEmpty) {
        _messages.addAll(saved);
      }
    });
    _runtime.bindMessages(_messages);
    _scrollToBottom(force: true);
  }

  void _onRuntimeChanged() {
    if (!mounted) return;
    final runtimeReply = _runtime.activeReply;
    final reasoningLength = runtimeReply == null
        ? 0
        : (runtimeReply.reasonings.isNotEmpty
              ? runtimeReply.reasonings.fold<int>(
                  0,
                  (total, value) => total + value.length,
                )
              : runtimeReply.reasoning.length);
    final contentLength = runtimeReply?.content.length ?? 0;
    final sameViewportReply = identical(_viewportRuntimeReply, runtimeReply);
    final reasoningOnlyGrowth =
        sameViewportReply &&
        reasoningLength > _viewportReasoningLength &&
        contentLength == _viewportContentLength;
    final shouldPreserveReasoningViewport =
        runtimeReply != null &&
        reasoningOnlyGrowth &&
        _latestThinkingExpanded(runtimeReply);
    final thinkingAnchorKey = shouldPreserveReasoningViewport
        ? _latestThinkingKey(runtimeReply)
        : null;
    final thinkingAnchor = thinkingAnchorKey != null
        ? _captureThinkingAnchor(thinkingAnchorKey, requireVisible: true)
        : null;
    final preserveReasoningViewport = thinkingAnchor != null;
    if (runtimeReply != null &&
        !identical(_replyPresentation.reply, runtimeReply)) {
      _resetReplyPresentation();
      _replyPresentation.bind(runtimeReply);
    }
    final pacedReply = runtimeReply ?? _replyPresentation.reply;
    if (pacedReply != null && identical(_replyPresentation.reply, pacedReply)) {
      for (final delta in _replyPresentation.captureNewText(pacedReply)) {
        _enqueueReplyText(
          delta.text,
          round: delta.round,
          target: delta.target,
          slot: delta.slot,
        );
      }
      if (_segments.isNotEmpty || _pending.isNotEmpty) {
        _typeTimer ??= Timer.periodic(_tick, (_) => _typeTick());
      }
    }
    if (!_runtime.isSending && pacedReply != null) {
      _replyPresentation.markTerminal();
      _streamDone = true;
      _typeTimer ??= Timer.periodic(_tick, (_) => _typeTick());
    } else {
      _streamDone = false;
    }
    setState(() {
      _sending = _runtime.isSending;
      _busy = _runtime.busy;
      _busyRound = _runtime.busyRound;
      _termuxRunning = _runtime.deviceRunning;
      _activeReply = runtimeReply;
      if (runtimeReply != null && runtimeReply.reasonings.isNotEmpty) {
        // RuntimeController owns canonical reasoning accumulation. Mirror the
        // latest complete in-memory round directly; never pace reasoning with
        // the正文 typewriter/pause queue.
        _thinkingShown = runtimeReply.reasonings.last;
        _thinkingReply = runtimeReply;
      } else if (!_runtime.isSending) {
        _thinkingReply = null;
      }
      _typing = false;
    });
    _viewportRuntimeReply = runtimeReply;
    _viewportReasoningLength = reasoningLength;
    _viewportContentLength = contentLength;
    if (preserveReasoningViewport) {
      _preserveExpandedReasoningViewport(key: thinkingAnchorKey!);
    } else {
      _scrollToBottom();
    }
  }

  void _resetReplyPresentation() {
    _typeTimer?.cancel();
    _typeTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pending = '';
    _pendingLastDeltaAt = null;
    _pendingIdleTimer?.cancel();
    _pendingIdleTimer = null;
    _pendingRevision = 0;
    _pendingRound = 0;
    _pendingTarget = null;
    _pendingSlot = null;
    _currentSeg = '';
    _currentSegTarget = null;
    _currentSegSlot = null;
    _segments.clear();
    _pausing = false;
    _streamDone = false;
    _replyPresentation.clear();
  }

  // 心跳轮询只刷新通知状态；/pending transport 由 AppEventClient 统一持有。
  void _startHeartbeatPolling() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(NotifyPanel.instance.pollStatus());
    });
  }

  /// 工具执行完成（v0.2.168）：busy 占位不消失，变成"✓ 搞定了！"永久记录。
  /// v0.2.169：正在流式的回复把完成轮次记到 reply.toolDoneRounds（落盘、
  /// 重启后仍在），渲染时与思考轮次穿插，不再插独立 tool_done 消息；
  /// 心跳静默工具（round==0 / 没有流式占位）保持原来的独立 tool_done
  /// 消息追加到对话流。多轮工具各自完成后各记一条，按轮次排列。
  // RuntimeController 已接管 generation tool lifecycle；旧 helper 暂留给
  // ChatPage 动画兜底，等 UI 输出节奏单独清理时再删除。
  // ignore: unused_element
  void _insertToolDoneMarker() {
    if (!mounted) return;
    final reply = _activeReply;
    final round = _busyRound;
    if (reply != null && round > 0) {
      setState(() {
        if (reply.parts.isNotEmpty) {
          _upsertToolPart(
            reply,
            ChatMessagePart(
              type: ChatMessagePartType.tool,
              round: round,
              status: 'done',
            ),
          );
        }
        final mutable = List<int>.from(reply.toolDoneRounds);
        if (!mutable.contains(round)) {
          mutable.add(round);
        }
        reply.toolDoneRounds = mutable;
        _busy = false;
        _busyRound = 0;
        _termuxRunning = false;
      });
    } else {
      final marker = ChatMessage(
        role: 'tool_done',
        content: ChatMessage.toolDoneLabel,
      );
      setState(() {
        _busy = false;
        _busyRound = 0;
        _termuxRunning = false;
        if (reply != null) {
          final idx = _messages.indexOf(reply);
          if (idx >= 0) {
            _messages.insert(idx, marker);
          } else {
            _messages.add(marker);
          }
        } else {
          _messages.add(marker);
        }
      });
    }
    ChatStore.save(_messages);
    _scrollToBottom();
  }

  String _thinkingKey(ChatMessage message, int round) =>
      '${identityHashCode(message)}:$round';

  String _latestThinkingKey(ChatMessage message) {
    final round = message.reasonings.isNotEmpty ? message.reasonings.length : 1;
    return _thinkingKey(message, round);
  }

  bool _latestThinkingExpanded(ChatMessage message) {
    return _expandedThinking.contains(_latestThinkingKey(message));
  }

  void _preserveExpandedReasoningViewport({required String key}) {
    _userViewingHistory = true;
    final oldExtent = _thinkingCardExtents[key];
    if (oldExtent != null) {
      _scroll.preserveAnchorOnNextLayout(key, oldExtent);
    }
  }

  double? _captureThinkingAnchor(String key, {bool requireVisible = false}) {
    if (!_scroll.hasClients) return null;
    final anchorContext = _thinkingAnchorKeys[key]?.currentContext;
    final anchorBox = anchorContext?.findRenderObject();
    if (anchorBox is! RenderBox || !anchorBox.attached || !anchorBox.hasSize) {
      return null;
    }
    if (requireVisible) {
      final viewport = RenderAbstractViewport.maybeOf(anchorBox);
      final viewportBox = viewport as RenderBox?;
      if (viewportBox == null || !viewportBox.hasSize) return null;
      final anchorRect = anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
      final viewportRect =
          viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
      if (!anchorRect.overlaps(viewportRect)) return null;
    }
    return anchorBox.localToGlobal(Offset.zero).dy;
  }

  void _toggleThinkingExpanded(ChatMessage message, int round) {
    final key = _thinkingKey(message, round);
    final anchorDy = _captureThinkingAnchor(key);
    if (anchorDy != null) {
      final oldExtent = _thinkingCardExtents[key];
      if (oldExtent != null) {
        _scroll.preserveAnchorOnNextLayout(key, oldExtent);
      }
      _userViewingHistory = true;
    }

    setState(() {
      if (!_expandedThinking.remove(key)) {
        _expandedThinking.add(key);
      }
    });

    if (anchorDy == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleScrollChanged();
      });
    }
  }

  void _toggleProcessSection(String key) {
    _toggleViewportAnchoredSet(
      _expandedProcessSections,
      key,
      oldExtent: _processSectionExtents[key],
    );
  }

  void _toggleToolExpanded(String key) {
    _toggleViewportAnchoredSet(
      _expandedTools,
      key,
      oldExtent: _toolStepExtents[key],
    );
  }

  void _toggleViewportAnchoredSet(
    Set<String> expandedSet,
    String key, {
    required double? oldExtent,
  }) {
    final canAnchor = _scroll.hasClients && oldExtent != null;
    if (canAnchor) {
      _scroll.preserveAnchorOnNextLayout(key, oldExtent);
      _userViewingHistory = true;
    }

    setState(() {
      if (!expandedSet.remove(key)) expandedSet.add(key);
    });

    if (!canAnchor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleScrollChanged();
      });
    }
  }

  String _processSectionKey(ChatMessage message, ChatProcessSection section) =>
      '${identityHashCode(message)}:process:${section.startIndex}';

  String _toolKey(ChatMessage message, int index, ChatMessagePart part) =>
      '${identityHashCode(message)}:${part.round}:$index';

  String _toolDisplayName(String raw) => chatToolDisplayName(raw);

  List<String> _toolNames(ChatMessagePart part) {
    final names = <String>[];
    for (final tool in part.tools) {
      final name = _toolDisplayName(tool.name);
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names;
  }

  String get _toolRunningLabel => chatBusyLabel(deviceRunning: _termuxRunning);

  String _toolPartTitle(ChatMessagePart part, {required bool running}) =>
      chatToolStepLabel(
        status: part.status,
        running: running,
        deviceRunning: _termuxRunning,
        toolNames: _toolNames(part),
      );

  // Runtime owns empty-response replacement; retained only for the legacy
  // page-side stream adapter below.
  // ignore: unused_element
  bool _replyHasVisibleOutput(ChatMessage reply) {
    return reply.content.trim().isNotEmpty ||
        reply.parts.any(
          (part) => switch (part.type) {
            ChatMessagePartType.text => part.text.trim().isNotEmpty,
            ChatMessagePartType.image => part.url.trim().isNotEmpty,
            ChatMessagePartType.tool =>
              part.status == 'done' ||
                  part.tools.any((tool) => tool.result.trim().isNotEmpty),
            ChatMessagePartType.reasoning => false,
          },
        ) ||
        (reply.imageUrl != null && reply.imageUrl!.isNotEmpty) ||
        reply.imageUrls.isNotEmpty ||
        reply.toolDoneRounds.isNotEmpty;
  }

  // Runtime owns empty-response replacement; retained only for the legacy
  // page-side stream adapter below.
  // ignore: unused_element
  void _replaceReplyWithNoResponse(ChatMessage reply, String content) {
    final idx = _messages.indexOf(reply);
    final card = ChatMessage(
      role: 'activity',
      content: content.trim().isEmpty ? '无回应' : content.trim(),
      time: reply.time,
    );
    if (idx >= 0) {
      _messages[idx] = card;
    } else if (!_messages.any(
      (m) => m.isActivity && m.content == card.content && m.time == card.time,
    )) {
      _messages.add(card);
    }
  }

  ChatMessagePart _ensureTextTimelinePart(ChatMessage reply, int round) {
    final parts = List<ChatMessagePart>.from(reply.parts);
    if (parts.isNotEmpty &&
        parts.last.type == ChatMessagePartType.text &&
        parts.last.round == round) {
      return parts.last;
    }
    final part = ChatMessagePart(type: ChatMessagePartType.text, round: round);
    parts.add(part);
    reply.parts = parts;
    return part;
  }

  void _enqueueReplyText(
    String text, {
    required int round,
    ChatMessagePart? target,
    String? slot,
  }) {
    if (text.isEmpty) return;
    _rawReply += text;
    if (_pending.isNotEmpty &&
        (_pendingRound != round || _pendingSlot != slot)) {
      if (_pending.trim().isNotEmpty) {
        _segments.add(_TextSegment(_pending, _pendingTarget, _pendingSlot));
      }
      _pending = '';
    }
    _pendingRound = round;
    _pendingTarget = target;
    _pendingSlot = slot;
    _pending += text;
    _pendingLastDeltaAt = DateTime.now();
    _pendingRevision += 1;
    while (true) {
      final idx = _pending.indexOf('\n');
      if (idx < 0) break;
      final seg = _pending.substring(0, idx + 1);
      _pending = _pending.substring(idx + 1);
      if (seg.trim().isNotEmpty) {
        _segments.add(_TextSegment(seg, _pendingTarget, _pendingSlot));
      }
    }
    if (_pending.isEmpty) {
      _pendingTarget = null;
      _pendingSlot = null;
      _pendingLastDeltaAt = null;
      _pendingIdleTimer?.cancel();
      _pendingIdleTimer = null;
    } else {
      _schedulePendingIdleFlush();
    }
  }

  void _appendVisibleText(
    String canonicalText,
    String visibleText, {
    ChatMessagePart? target,
    String? slot,
  }) {
    if (canonicalText.isEmpty) return;
    _replyPresentation.reveal(
      canonicalText,
      visibleText,
      target: target,
      slot: slot,
    );
  }

  void _appendReasoningPart(
    ChatMessage reply,
    String rawText, {
    required int round,
    required String status,
  }) {
    final clean = _stripToolTags(rawText);
    if (clean.isEmpty && status != 'done') return;
    final idx = math.max(round, 1) - 1;
    final mutable = List<String>.from(reply.reasonings);
    while (mutable.length < idx) {
      mutable.add('');
    }
    // v0.2.181：尾部去重——同一段思考被上游/服务端重复推送时（精简版+完整版
    // 双来源），只保留一份，防同一消息渲染出两个思考气泡。
    final existingTail = mutable.isEmpty || mutable.length <= idx
        ? ''
        : mutable[idx];
    final dupTail = clean.length >= 4 && existingTail.endsWith(clean);
    if (!dupTail && mutable.length == idx) {
      if (reply.reasoning.isNotEmpty && clean.isNotEmpty) {
        reply.reasoning += '\n\n';
      }
      mutable.add(clean);
    } else if (!dupTail && clean.isNotEmpty) {
      mutable[idx] = mutable[idx] + clean;
    }
    reply.reasonings = mutable;
    if (!dupTail && clean.isNotEmpty) reply.reasoning += clean;
    _thinkingShown = reply.reasonings.isEmpty ? '' : reply.reasonings.last;

    final parts = List<ChatMessagePart>.from(reply.parts);
    var partIndex = -1;
    for (var i = parts.length - 1; i >= 0; i--) {
      final part = parts[i];
      if (part.type == ChatMessagePartType.text ||
          part.type == ChatMessagePartType.image) {
        break;
      }
      if (part.type == ChatMessagePartType.reasoning && part.round == round) {
        partIndex = i;
        break;
      }
    }
    if (partIndex >= 0) {
      if (!dupTail) parts[partIndex].text += clean;
      parts[partIndex].status = status;
    } else if (partIndex < 0) {
      parts.add(
        ChatMessagePart(
          type: ChatMessagePartType.reasoning,
          text: clean,
          round: round,
          status: status,
        ),
      );
    }
    reply.parts = parts;
  }

  void _upsertToolPart(ChatMessage reply, ChatMessagePart incoming) {
    final round = incoming.round <= 0 ? _busyRound : incoming.round;
    final parts = List<ChatMessagePart>.from(reply.parts);
    var idx = -1;
    // 工具完成事件可能在正文首段已经到达后才补发。round 才是同一轮工具
    // 的稳定关联键，不能被 text/image 边界截断，否则会在正文后追加一个
    // 空的 done tool part，渲染成第二个“搞定了”过程气泡。
    for (var i = parts.length - 1; i >= 0; i--) {
      final part = parts[i];
      if (part.type == ChatMessagePartType.tool && part.round == round) {
        idx = i;
        break;
      }
    }
    final part = ChatMessagePart(
      type: ChatMessagePartType.tool,
      round: round,
      status: incoming.status.isEmpty ? 'running' : incoming.status,
      tools: incoming.tools,
    );
    if (idx >= 0) {
      final existing = parts[idx];
      final merged = <String, ChatToolCallPart>{
        for (final t in existing.tools) t.id.isNotEmpty ? t.id : t.name: t,
      };
      for (final t in incoming.tools) {
        final key = t.id.isNotEmpty ? t.id : t.name;
        final old = merged[key];
        merged[key] = old == null
            ? t
            : old.copyWith(
                name: t.name.isEmpty ? old.name : t.name,
                arguments: t.arguments.isEmpty ? old.arguments : t.arguments,
                status: t.status.isEmpty ? old.status : t.status,
                result: t.result.isEmpty ? old.result : t.result,
              );
      }
      existing
        ..status = part.status
        ..tools = merged.values.toList();
    } else {
      parts.add(part);
    }
    reply.parts = parts;
    if (part.status == 'done' && round > 0) {
      final done = List<int>.from(reply.toolDoneRounds);
      if (!done.contains(round)) {
        done.add(round);
        reply.toolDoneRounds = done;
      }
    }
  }

  void _appendImagePart(ChatMessage reply, String url) {
    if (url.isEmpty) return;
    final parts = List<ChatMessagePart>.from(reply.parts)
      ..add(ChatMessagePart(type: ChatMessagePartType.image, url: url));
    reply.parts = parts;
    if (reply.imageUrl == null || reply.imageUrl!.isEmpty) {
      reply.imageUrl = url;
    } else if (!reply.imageUrls.contains(url)) {
      reply.imageUrls = List<String>.from(reply.imageUrls)..add(url);
    }
  }

  // RuntimeController 已接管 stream event 应用；旧 helper 暂留给 ChatPage 动画兜底。
  // ignore: unused_element
  void _applyIncomingPart(ChatMessage reply, ChatMessagePart part) {
    if (!mounted) return;
    _typingAnim.stop();
    setState(() {
      _typing = false;
      switch (part.type) {
        case ChatMessagePartType.text:
          // v0.2.176 真正修复：8816 正文走 part 事件（onDelta 在 parts 模式下不触发）。
          // 正文 part 不实时上屏，先进停顿队列，由 _typeTick 按段间字数停顿显示，
          // 呼吸感恢复；思考 part 仍实时（下方 reasoning 分支不动）。
          {
            final delta = part.delta.isNotEmpty ? part.delta : part.text;
            final round = part.round <= 0 ? 0 : part.round;
            final target = _ensureTextTimelinePart(reply, round);
            _enqueueReplyText(delta, round: round, target: target);
            _typeTimer ??= Timer.periodic(_tick, (_) => _typeTick());
          }
        case ChatMessagePartType.reasoning:
          _appendReasoningPart(
            reply,
            part.delta.isNotEmpty ? part.delta : part.text,
            round: part.round <= 0 ? 1 : part.round,
            status: part.status.isEmpty ? 'streaming' : part.status,
          );
          _thinkingReply = reply;
        case ChatMessagePartType.tool:
          _upsertToolPart(reply, part);
        case ChatMessagePartType.image:
          _appendImagePart(reply, part.url);
      }
    });
    _scrollToBottom();
  }

  // RuntimeController 已接管 stream terminal 应用；旧 helper 暂留给 ChatPage 动画兜底。
  // ignore: unused_element
  void _markPartsDone(ChatMessage reply) {
    if (reply.parts.isEmpty) return;
    final parts = List<ChatMessagePart>.from(reply.parts);
    for (final part in parts) {
      if ((part.type == ChatMessagePartType.reasoning ||
              part.type == ChatMessagePartType.tool) &&
          part.status == 'streaming') {
        part.status = 'done';
      }
      if (part.type == ChatMessagePartType.tool && part.status == 'running') {
        part.status = 'done';
      }
    }
    reply.parts = parts;
  }

  // RuntimeController 已接管 stream failure 应用；旧 helper 暂留给 ChatPage 动画兜底。
  // ignore: unused_element
  void _markLatestProcessSectionFailed(ChatMessage reply) {
    if (reply.parts.isEmpty) return;
    final parts = List<ChatMessagePart>.from(reply.parts);
    var end = -1;
    for (var i = parts.length - 1; i >= 0; i--) {
      final type = parts[i].type;
      if (type == ChatMessagePartType.reasoning ||
          type == ChatMessagePartType.tool) {
        end = i;
        break;
      }
      if (type == ChatMessagePartType.text ||
          type == ChatMessagePartType.image) {
        return;
      }
    }
    if (end < 0) return;
    var start = end;
    while (start > 0) {
      final prevType = parts[start - 1].type;
      if (prevType != ChatMessagePartType.reasoning &&
          prevType != ChatMessagePartType.tool) {
        break;
      }
      start -= 1;
    }
    for (var i = start; i <= end; i++) {
      if (parts[i].status != 'failed') {
        parts[i].status = 'failed';
      }
    }
    reply.parts = parts;
  }

  void _restoreFailedMessage(ChatMessage message) {
    if (_sending) return;
    setState(() {
      _messages.remove(message);
      _input.text = message.content;
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    });
    ChatStore.save(_messages);
    _inputFocus.requestFocus();
  }

  @override
  void dispose() {
    _runtime.removeListener(_onRuntimeChanged);
    _runtime.unbindMessages(_messages);
    WidgetsBinding.instance.removeObserver(this);
    _typeTimer?.cancel();
    _pauseTimer?.cancel();
    _pendingIdleTimer?.cancel();
    _focusTimer?.cancel();
    _heartbeatTimer?.cancel();
    _scrollJumpButtonsTimer?.cancel();
    _typingAnim.dispose();
    _drawerCtrl.dispose();
    _inputFocus.dispose();
    _input.dispose();
    _scroll.removeListener(_handleScrollChanged);
    _scroll.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    // The chat list is reversed so offset 0 is the newest/bottom edge. This
    // makes cold start and long histories land on the latest message without
    // walking an estimated maxScrollExtent through hundreds of lazy items.
    return position.pixels - position.minScrollExtent <=
        _autoScrollLockThreshold;
  }

  bool get _isAtBottomEdge {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    return position.pixels - position.minScrollExtent <= 2;
  }

  void _handleScrollChanged() {
    if (!_scroll.hasClients) return;
    if (_userScrollingMessages) {
      // A deliberate finger drag owns the viewport immediately. Even moving a
      // few pixels away from the live tail must stop streaming auto-follow;
      // otherwise each reasoning delta yanks the user back down.
      _userViewingHistory = !_isAtBottomEdge;
      return;
    }
    if (_userViewingHistory) {
      // Once the user has taken control, keep that lock sticky until they
      // actually return to the bottom edge (or tap the bottom jump button).
      if (_isAtBottomEdge) _userViewingHistory = false;
      return;
    }
    if (!_isNearBottom) _userViewingHistory = true;
  }

  bool _handleMessageScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrollingMessages = true;
      _scrollJumpButtonsTimer?.cancel();
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _userScrollingMessages = true;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _userScrollingMessages = true;
    } else if (notification is ScrollEndNotification &&
        _userScrollingMessages) {
      _userScrollingMessages = false;
      _showScrollJumpButtonsBriefly();
    }
    return false;
  }

  void _showScrollJumpButtonsBriefly() {
    if (!mounted || _messages.isEmpty) return;
    _scrollJumpButtonsTimer?.cancel();
    if (!_showScrollJumpButtons) {
      setState(() => _showScrollJumpButtons = true);
    }
    _scrollJumpButtonsTimer = Timer(
      const Duration(seconds: 2),
      _hideScrollJumpButtons,
    );
  }

  void _hideScrollJumpButtons() {
    if (!mounted || !_showScrollJumpButtons) return;
    setState(() => _showScrollJumpButtons = false);
  }

  bool _canAutoScroll({bool force = false}) {
    if (force) return true;
    // 手指正在拖列表时一律不自动滚；拖动结束后也尊重 sticky history lock。
    // 只有真正回到底部边缘或显式点“到底部”才恢复流式跟随。
    if (_userScrollingMessages) return false;
    return !_userViewingHistory;
  }

  void _jumpToBottom({bool force = false}) {
    if (!_canAutoScroll(force: force)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_canAutoScroll(force: force)) {
        return;
      }
      _scroll.jumpTo(_scroll.position.minScrollExtent);
    });
  }

  void _scrollToBottom({bool force = false}) {
    if (!_canAutoScroll(force: force)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_canAutoScroll(force: force)) {
        return;
      }
      final bottom = _scroll.position.minScrollExtent;
      if (force) {
        _scroll.jumpTo(bottom);
        _handleScrollChanged();
        return;
      }
      final distance = (_scroll.position.pixels - bottom).abs();
      if (distance < 1) {
        _handleScrollChanged();
        return;
      }
      unawaited(
        _scroll
            .animateTo(
              bottom,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
            )
            .whenComplete(_handleScrollChanged),
      );
    });
  }

  Duration _scrollJumpDuration(double distance) {
    final milliseconds = (240 + distance / 5).clamp(260, 680).round();
    return Duration(milliseconds: milliseconds);
  }

  void _animateChatListTo(double target) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final clampedTarget = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final distance = (position.pixels - clampedTarget).abs();
    if (distance < 1) {
      _handleScrollChanged();
      return;
    }
    unawaited(
      _scroll
          .animateTo(
            clampedTarget,
            duration: _scrollJumpDuration(distance),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(_handleScrollChanged),
    );
  }

  void _scrollChatListToTop() {
    if (!_scroll.hasClients) return;
    // Reverse list: maxScrollExtent is the oldest/top edge.
    _userViewingHistory = true;
    _showScrollJumpButtonsBriefly();
    _animateChatListTo(_scroll.position.maxScrollExtent);
  }

  void _scrollChatListToBottom() {
    if (!_scroll.hasClients) return;
    // Reverse list: minScrollExtent (0) is the newest/bottom edge.
    _userViewingHistory = false;
    _showScrollJumpButtonsBriefly();
    _animateChatListTo(_scroll.position.minScrollExtent);
  }

  // 输出 tick：不打字机了，整段直接出现；段间按下一段字数停顿（呼吸感）
  void _typeTick() {
    if (_pausing) return; // 段间停顿中
    // v0.2.119：思考内容已实时同步显示（onReasoning 直接写 _thinkingShown），
    // 正文段不再等思考追平，来了就实时显示
    if (_currentSeg.isEmpty) {
      if (_segments.isNotEmpty) {
        // 上一段已显示，按下一段字数决定停顿时长（代码块内行短停顿）
        final next = _segments.first.text;
        if (next.trimLeft().startsWith('```')) _inCodeBlock = !_inCodeBlock;
        _startPause(next.trim().length, inCode: _inCodeBlock);
        return;
      }
      // 队列空：_pending 里有没切到换行的内容。
      // 正常仍按 40 字切块；但 Provider 若在一个不足 40 字的片段后短暂停顿，
      // 不能把这段一直藏到流结束。空闲 260ms 后把当前片段冻结成下一段，
      // 后续仍走完全相同的按字数停顿公式，不改变既定节奏。
      if (_pendingReadyForPause) {
        _freezePendingAsNextSegment();
        final next = _segments.first.text;
        _startPause(next.trim().length, inCode: _inCodeBlock);
        return;
      }
      if (_streamDone) {
        // 全部显示完了，收尾
        _finishReplyPresentation();
        return;
      }
      return;
    }
    // 整段直接显示（无逐字效果）
    final seg = _currentSeg;
    final target = _currentSegTarget;
    final slot = _currentSegSlot;
    _currentSeg = '';
    _currentSegTarget = null;
    _currentSegSlot = null;
    if (!mounted) return;
    // 剥离工具标记（历史残留兜底，服务端已原生工具化不再输出）：
    // 不占正文。整段都是标记时跳过（等下个 tick 取下一段）
    final cleanSeg = _stripToolTags(seg);
    setState(() {
      _appendVisibleText(seg, cleanSeg, target: target, slot: slot);
    });
    _jumpToBottom();
  }

  bool get _pendingReadyForPause {
    if (_pending.isEmpty) return false;
    if (_streamDone || _pending.trim().length >= 40) return true;
    final lastDeltaAt = _pendingLastDeltaAt;
    if (lastDeltaAt == null) return false;
    return DateTime.now().difference(lastDeltaAt) >= _pendingSegmentIdle;
  }

  void _freezePendingAsNextSegment() {
    if (_pending.isEmpty) return;
    _pendingIdleTimer?.cancel();
    _pendingIdleTimer = null;
    _segments.add(_TextSegment(_pending, _pendingTarget, _pendingSlot));
    _pending = '';
    _pendingLastDeltaAt = null;
    _pendingRound = 0;
    _pendingTarget = null;
    _pendingSlot = null;
  }

  void _schedulePendingIdleFlush() {
    _pendingIdleTimer?.cancel();
    if (_pending.isEmpty) return;
    final reply = _replyPresentation.reply;
    final revision = _pendingRevision;
    _pendingIdleTimer = Timer(_pendingSegmentIdle, () {
      _pendingIdleTimer = null;
      if (!mounted ||
          _pending.isEmpty ||
          _pendingRevision != revision ||
          !identical(_replyPresentation.reply, reply)) {
        return;
      }
      _freezePendingAsNextSegment();
      _typeTimer ??= Timer.periodic(_tick, (_) => _typeTick());
    });
  }

  // 段间停顿：时长按下一段字数算（800ms + 每字 30ms，封顶 3.5s），
  // 字越多停越久，像人读完一句再开口。停顿中气泡下方显示三点。
  void _startPause(int nextLen, {bool inCode = false}) {
    _pausing = true;
    setState(() {});
    // 代码块内行用 120ms 短停顿，整块快速连出；普通文本按字数呼吸停顿
    final pauseMs = inCode ? 120 : (800 + nextLen * 30).clamp(800, 3500);
    _pauseTimer?.cancel();
    _pauseTimer = Timer(Duration(milliseconds: pauseMs), () {
      if (!mounted) return;
      setState(() {
        _pausing = false;
        if (_segments.isNotEmpty) {
          final next = _segments.removeAt(0);
          _currentSeg = next.text;
          _currentSegTarget = next.target;
          _currentSegSlot = next.slot;
        }
      });
      // 停顿结束后没有内容可吐且流已结束 → 收尾
      _maybeFinish();
    });
  }

  // 流结束后检查：队列/缓冲全空才真正收尾
  void _maybeFinish() {
    if (_streamDone &&
        _currentSeg.isEmpty &&
        _segments.isEmpty &&
        _pending.isEmpty &&
        !_pausing) {
      _finishReplyPresentation();
    }
  }

  // 视觉队列收尾：Runtime 已独立完成落盘、通知与 terminal lifecycle。
  void _finishReplyPresentation() {
    if (!mounted) return;
    _typeTimer?.cancel();
    _typeTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pendingRound = 0;
    _pendingTarget = null;
    _currentSegTarget = null;
    setState(() {
      _pausing = false;
      _streamDone = false;
      _replyPresentation.clear();
    });
    _scrollToBottom();
  }

  /// 剥离工具标记：画图 [gen_image]/搜索 [search] 只作历史残留兜底（服务端已原生
  /// 工具化不再输出），[ask]/[calendar_*] 走各自链路，都不占正文。
  static String _stripToolTags(String s) => s
      .replaceAll(RegExp(r'\[gen_image\][\s\S]*?\[/gen_image\]'), '')
      .replaceAll(RegExp(r'\[search\][\s\S]*?\[/search\]'), '')
      .replaceAll(RegExp(r'\[ask\][\s\S]*?\[/ask\]'), '')
      .replaceAll(RegExp(r'\[ask\s*[:：][^\]]*\]'), '')
      .replaceAll(RegExp(r'\[calendar_query\][\s\S]*?\[/calendar_query\]'), '')
      .replaceAll(RegExp(r'\[calendar_query\s*[:：][^\]]*\]'), '')
      .replaceAll(
        RegExp(r'\[calendar_create\][\s\S]*?\[/calendar_create\]'),
        '',
      )
      .replaceAll(RegExp(r'\[calendar_create\s*[:：][^\]]*\]'), '')
      .replaceAll(
        RegExp(
          r'<(?:\|[^>|]+\|)?tool_calls\b[^>]*>[\s\S]*?</(?:\|[^>|]+\|)?tool_calls\s*>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'<(?:\|[^>|]+\|)?invoke\b[^>]*>[\s\S]*?</(?:\|[^>|]+\|)?invoke\s*>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(r'<(?:\|[^>|]+\|)?invoke\b[^>]*/\s*>', caseSensitive: false),
        '',
      )
      // v0.2.114：渲染兜底剥 [shell]（正常 8816 已剥干净，这里防旧历史/残留，
      // 兼容 [shell]...[/shell] 与 [shell: 命令] 变体）
      .replaceAll(RegExp(r'\[shell\][\s\S]*?\[/shell\]'), '')
      .replaceAll(RegExp(r'\[shell\s*[:：][^\]]*\]'), '')
      // v0.2.153：兜底剥 [tool: termux] 标记（正常 8816 已剥干净，这里防旧历史/残留）
      .replaceAll(RegExp(r'\[tool\][\s\S]*?\[/tool\]'), '')
      .replaceAll(RegExp(r'\[tool\s*[:：][^\]]*\][\s\S]*?\[/tool\]'), '')
      .replaceAll('[tool]', '')
      .replaceAll('[/tool]', '')
      .replaceAll('[shell]', '')
      .replaceAll('[/shell]', '')
      .replaceAll('[ask]', '')
      .replaceAll('[/ask]', '')
      .replaceAll('[calendar_query]', '')
      .replaceAll('[/calendar_query]', '')
      .replaceAll('[calendar_create]', '')
      .replaceAll('[/calendar_create]', '');

  /// AI 提问链路：从流式原始内容提取 [ask]问题 | 选项1,选项2[/ask]，
  /// 弹一个底部提问框（选项单点即答 + 底部自由输入），用户作答后作为 user 消息继续对话。
  /// 提取不到标记直接返回，不打断收尾。
  // Runtime owns terminal follow-up handling; the presentation queue must not
  // invoke it when visual pacing drains.
  // ignore: unused_element
  Future<void> _handleAskUser(ChatMessage reply) async {
    final m = RegExp(
      r'\[ask\]([\s\S]*?)\[/ask\]|\[ask\s*[:：]([^\]]*)\]',
    ).firstMatch(_rawReply);
    if (m == null) return;
    final body = (m.group(1) ?? m.group(2) ?? '').trim();
    if (body.isEmpty) return;
    final parts = body.split('|');
    final question = parts.first.trim();
    final options = parts.length > 1
        ? parts
              .sublist(1)
              .join(',')
              .split(RegExp(r'[,，]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    if (question.isEmpty) return;
    final answer = await _showAskDialog(question, options);
    if (!mounted || answer == null || answer.trim().isEmpty) return;
    _sendText(answer.trim());
  }

  /// 系统日历链路：从流式原始内容提取 [calendar_query]/[calendar_create] 标记，
  /// 调手机系统日历（NudgeTools）执行，再把结果作为仅模型可见的消息回传总结。
  // Runtime owns terminal follow-up handling; the presentation queue must not
  // invoke it when visual pacing drains.
  // ignore: unused_element
  Future<void> _handleCalendarTool(ChatMessage reply) async {
    final queryMatch = RegExp(
      r'\[calendar_query\]([\s\S]*?)\[/calendar_query\]|\[calendar_query\s*[:：]([^\]]*)\]',
    ).firstMatch(_rawReply);
    final createMatch = RegExp(
      r'\[calendar_create\]([\s\S]*?)\[/calendar_create\]|\[calendar_create\s*[:：]([^\]]*)\]',
    ).firstMatch(_rawReply);
    if (queryMatch == null && createMatch == null) return;
    final block = createMatch != null
        ? await _runCalendarCreate(
            createMatch.group(1) ?? createMatch.group(2) ?? '',
          )
        : await _runCalendarQuery(
            queryMatch?.group(1) ?? queryMatch?.group(2) ?? '7',
          );
    if (!mounted || block.isEmpty) return;
    await _sendCalendarConclusion(reply, block);
  }

  /// 底部提问框：选项轻触后立即选中并锁定，底部仍保留自由输入；
  /// 跳过返回 null，发送返回最终回答。
  Future<String?> _showAskDialog(String question, List<String> options) async {
    final ctrl = TextEditingController();
    Timer? loadingTimer;
    var completed = false;
    var locked = false;
    var showLoading = false;
    String? selectedOption;
    final res = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final media = MediaQuery.of(ctx);
        final visibleHeight =
            media.size.height -
            media.viewInsets.bottom -
            media.padding.top -
            12;
        final sheetMaxHeight = math.min(
          media.size.height * 0.74,
          math.max(220.0, visibleHeight),
        );
        void submitAnswer(String answer, StateSetter setSheetState) {
          final text = answer.trim();
          if (completed || text.isEmpty) return;
          completed = true;
          setSheetState(() {
            selectedOption = options.contains(text) ? text : null;
            locked = true;
            showLoading = false;
          });
          loadingTimer?.cancel();
          loadingTimer = Timer(const Duration(milliseconds: 150), () {
            if (ctx.mounted && locked) {
              setSheetState(() => showLoading = true);
            }
          });
          Future<void>.delayed(const Duration(milliseconds: 260), () {
            loadingTimer?.cancel();
            if (ctx.mounted) Navigator.pop(ctx, text);
          });
        }

        return Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: StatefulBuilder(
                  builder: (ctx, setSheetState) => ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: sheetMaxHeight),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 34,
                            height: 4,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Flexible(
                          fit: FlexFit.loose,
                          child: SingleChildScrollView(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  question,
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.45,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                if (options.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  for (var i = 0; i < options.length; i++) ...[
                                    if (i > 0) const SizedBox(height: 8),
                                    _AskOptionButton(
                                      label: options[i],
                                      selected: selectedOption == options[i],
                                      locked: locked,
                                      loading:
                                          showLoading &&
                                          selectedOption == options[i],
                                      onTap: locked
                                          ? null
                                          : () => submitAnswer(
                                              options[i],
                                              setSheetState,
                                            ),
                                    ),
                                  ],
                                ],
                                const SizedBox(height: 12),
                                TextField(
                                  controller: ctrl,
                                  autofocus: false,
                                  minLines: 1,
                                  maxLines: 3,
                                  enabled: !locked,
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) =>
                                      submitAnswer(ctrl.text, setSheetState),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.45,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: '也可以直接打字回答',
                                    hintStyle: TextStyle(
                                      color: theme.colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.66),
                                    ),
                                    filled: true,
                                    fillColor: context.fieldColor,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 11,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: locked
                                  ? null
                                  : () => Navigator.pop(ctx),
                              child: const Text('跳过'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: locked
                                  ? null
                                  : () =>
                                        submitAnswer(ctrl.text, setSheetState),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(72, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(22),
                                ),
                              ),
                              child: const Text('发送'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    loadingTimer?.cancel();
    ctrl.dispose();
    return res;
  }

  Future<String> _runCalendarQuery(String raw) async {
    final n = int.tryParse(raw.trim());
    final days = (n ?? 7).clamp(1, 31);
    final result = await NudgeApi.call(
      NudgeApi.calendarQuery,
      arguments: {'days': days},
    );
    return '【系统日历查询结果，不是用户发的内容】\n$result\n\n'
        '请根据上面的真实日历结果，用自然语言告诉用户未来 $days 天的日程；'
        '没有日程就说没有安排，不要编造。';
  }

  Future<String> _runCalendarCreate(String raw) async {
    Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(raw);
      args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      args = <String, dynamic>{};
    }
    if ((args['title'] as String? ?? '').trim().isEmpty) {
      return '【系统日历创建失败】缺少标题；请让用户补充日程标题和时间后重试。';
    }
    final result = await NudgeApi.call(
      NudgeApi.calendarCreate,
      arguments: args,
    );
    return '【系统日历创建结果，不是用户发的内容】\n$result\n\n'
        '请根据上面的真实结果，用自然语言告诉用户是否创建成功；不要编造。';
  }

  /// 日历工具结果回传总结：新建一条 assistant 消息，把结果作为仅模型可见消息
  /// 交给 8816 再总结成自然语言（复用 sendConclusion，链路与搜索一致）。
  Future<void> _sendCalendarConclusion(ChatMessage reply, String block) async {
    final conclusion = ChatMessage(role: 'assistant', content: '');
    final idx = _messages.indexOf(reply);
    setState(() {
      if (idx >= 0) {
        _messages.insert(idx + 1, conclusion);
      } else {
        _messages.add(conclusion);
      }
    });
    ChatStore.save(_messages);
    _scrollToBottom();
    final history = _messages.where((m) => m.content.isNotEmpty).toList();
    await ChatApi.sendConclusion(
      history,
      searchBlock: block,
      onDelta: (delta) {
        if (!mounted) return;
        setState(() => conclusion.content += delta);
        _scrollToBottom();
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          if (conclusion.content.trim().isEmpty) {
            _messages.remove(conclusion);
          }
        });
        ChatStore.save(_messages);
        _scrollToBottom();
      },
      onError: (err) {
        if (!mounted) return;
        setState(() {
          conclusion.content = conclusion.content.trim().isEmpty
              ? '（操作失败：$err）'
              : '${conclusion.content.trim()}\n（操作失败：$err）';
        });
        ChatStore.save(_messages);
      },
    );
  }

  // 打开历史 Hub：会话、搜索、日历、最近删除与当前对话导出统一从这里进入。
  // v0.2.94 抽屉返回修复：返回后 _drawerCtrl.value = 1 直设值无动画恢复
  // 抽屉展开状态（不依赖 push 前抽屉状态，不重播拉开动画）
  Future<void> _openHistory() async {
    final index = await Navigator.push<int>(
      context,
      SwipeBackRoute(
        builder: (_) => HistoryHubPage(currentMessages: _messages),
      ),
    );
    if (!mounted) return;
    _drawerCtrl.value = 1;
    _focusMessageAt(index);
  }

  // 打开记忆面板（记忆库 8820：统计/日历热力/分类入口/近两天+全部日期）。
  // v0.2.94 抽屉返回修复：同归档，返回后 value = 1
  Future<void> _openMemory() async {
    await Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const MemoryPage()),
    );
    if (mounted) _drawerCtrl.value = 1;
  }

  // 打开AI 助手 Hub：资料、心情、个人内容。
  Future<void> _openAssistant() async {
    await Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const AssistantHubPage()),
    );
    if (mounted) _drawerCtrl.value = 1;
  }

  // 打开一起 Hub：小家、一起听、一起读、旅行、提问瓶。
  Future<void> _openTogether() async {
    await Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const TogetherHubPage()),
    );
    if (mounted) _drawerCtrl.value = 1;
  }

  // 能力直接复用工具箱主体，仅替换顶层可见标题。
  Future<void> _openAbility() async {
    await Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const ToolboxPage(title: '能力')),
    );
    if (mounted) _drawerCtrl.value = 1;
  }

  /// 圆润浮动提示（胶囊 SnackBar，平滑弹出）
  void _showToast(String msg) {
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          elevation: 0,
        ),
      );
  }

  double _drawerWidthFor(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    return math.min(screenW * _drawerWidthFactor, _drawerMaxWidth);
  }

  void _animateDrawerTo(double target) {
    _drawerCtrl.animateTo(
      target,
      duration: _drawerAnimationDuration,
      curve: Curves.easeOutCubic,
    );
  }

  void _resetDrawerDragState() {
    _drawerDragAccepted = false;
    _drawerDragRejected = false;
  }

  void _handleDrawerDragStart(DragStartDetails details) {
    _drawerCtrl.stop();
    _dragStartDx = details.globalPosition.dx;
    _dragStartDy = details.globalPosition.dy;
    _dragStartValue = _drawerCtrl.value;
    _drawerDragAccepted = _dragStartValue > 0.01;
    _drawerDragRejected = _userScrollingMessages;
  }

  void _handleDrawerDragUpdate(
    BuildContext context,
    DragUpdateDetails details,
  ) {
    if (_drawerDragRejected) return;

    final dx = details.globalPosition.dx - _dragStartDx;
    final dy = details.globalPosition.dy - _dragStartDy;

    if (!_drawerDragAccepted) {
      if (_dragStartValue <= 0.01) {
        if (dx <= 0 || dx < _drawerDragActivationDistance) return;
      } else if (dx.abs() < 6) {
        return;
      }

      final horizontalEnough = dx.abs() >= dy.abs() * _drawerDirectionRatio;
      if (!horizontalEnough) {
        if (dy.abs() > _drawerDragActivationDistance) {
          _drawerDragRejected = true;
        }
        return;
      }

      _drawerDragAccepted = true;
    }

    final width = _drawerWidthFor(context);
    final effectiveDx = _dragStartValue <= 0.01 && dx > 0
        ? math.max(0.0, dx - _drawerDragActivationDistance)
        : dx;
    _drawerCtrl.value = (_dragStartValue + effectiveDx / width).clamp(0.0, 1.0);
  }

  void _handleDrawerDragEnd(DragEndDetails details) {
    final v = details.velocity.pixelsPerSecond.dx;

    if (!_drawerDragRejected && _drawerDragAccepted) {
      if (v > _drawerFlingVelocity) {
        _openDrawer();
        _resetDrawerDragState();
        return;
      }
      if (v < -_drawerFlingVelocity) {
        _closeDrawer();
        _resetDrawerDragState();
        return;
      }
    }

    final value = _drawerDragAccepted ? _drawerCtrl.value : _dragStartValue;
    _animateDrawerTo(value >= _drawerSettleThreshold ? 1 : 0);
    _resetDrawerDragState();
  }

  void _handleDrawerDragCancel() {
    _animateDrawerTo(_drawerCtrl.value >= _drawerSettleThreshold ? 1 : 0);
    _resetDrawerDragState();
  }

  // 跟手抽屉：开/关
  void _openDrawer() {
    FocusManager.instance.primaryFocus?.unfocus();
    _animateDrawerTo(1);
  }

  void _closeDrawer() {
    _animateDrawerTo(0);
  }

  // 打开设置页，返回后 value = 1 无动画恢复抽屉（v0.2.94 抽屉返回修复）
  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(SwipeBackRoute(builder: (_) => const SettingsPage()));
    if (mounted) _drawerCtrl.value = 1;
  }

  // 打开 canonical 搜索页，当前窗口只作为 eventId 精确定位上下文。
  Future<void> _openSearch() async {
    final idx = await Navigator.push<int>(
      context,
      SwipeBackRoute(builder: (_) => SearchPage(currentMessages: _messages)),
    );
    if (!mounted) return;
    _focusMessageAt(idx);
  }

  void _focusMessageAt(int? idx) {
    if (idx == null || idx < 0 || idx >= _messages.length) return;
    setState(() {
      _focusIndex = idx;
      _focusPending = true;
    });
    // 目标可能在可视区外（懒加载）。列表 reverse 后 offset 0 对应最新
    // 消息，因此先用“离末尾还有多少条”估算，再由 ensureVisible 精确对齐。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final reverseIndex = _messages.length - 1 - idx;
      final est = (reverseIndex * 90.0).clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(est);
    });
  }

  // 开始新对话：Runtime 原子关闭当前 epoch，可选归入 server folder，再开新 epoch。
  // 手机只清当前窗口展示缓存，不再新增本地归档副本。
  Future<void> _startNewChat() async {
    final hasMessages = _messages.any((m) => m.content.trim().isNotEmpty);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开始新对话'),
        content: Text(
          hasMessages
              ? '当前对话会保存在服务器历史里，搜索和日历里随时能翻到，然后开一个干净的新窗口。'
              : '当前窗口还没有消息，直接开一个干净的新窗口。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('归档并开始'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 先完成归档所需的所有可取消选择；取消不能让服务器提前 rollover。
    ({String? id, String name})? archiveFolder;
    if (hasMessages) {
      archiveFolder = await _pickArchiveFolder();
      if (!mounted || archiveFolder == null) return;
    }
    final rollover = await ChatApi.rolloverRuntimeEpoch(
      epochId: RuntimeEventClient.newRuntimeId('epoch'),
      archiveFolderId: archiveFolder?.id,
    );
    if (rollover == null || rollover['ok'] != true) {
      if (mounted) _showToast('服务器暂时没能开始新对话');
      return;
    }
    // Runtime 已经原子归档旧 epoch；手机只清当前窗口展示缓存。
    await ChatStore.save(const []);
    if (!mounted) return;
    // 新窗口从空白开始（用户定的，和启动一致，不再塞开场白）
    _scrollJumpButtonsTimer?.cancel();
    setState(() {
      _messages.clear();
      _showScrollJumpButtons = false;
      _userScrollingMessages = false;
    });
    ChatStore.save(_messages);
    _scrollToBottom();
  }

  /// 归档位置选择：未分类（默认）+ 各文件夹；取消返回 null（中止归档）。
  Future<({String? id, String name})?> _pickArchiveFolder() =>
      showFolderPicker(context, title: '归档到');

  // 展开输入编辑器：4/5 屏底部卡片，可滚动编辑长文本。
  // 内容实时写回输入框，底部按钮只负责收起编辑器。
  void _openInputEditor() {
    final theme = Theme.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          final media = MediaQuery.of(ctx);
          final keyboard = media.viewInsets.bottom;
          final topGap = media.padding.top + 12;
          final availableHeight = (media.size.height - keyboard - topGap).clamp(
            220.0,
            media.size.height,
          );
          final sheetHeight = math.min(
            media.size.height * 0.82,
            availableHeight,
          );
          return AnimatedPadding(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: keyboard),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: sheetHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 顶部：只留一个居中的细把手（无标题行）
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 6),
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
                      // 正文：可滚动长文本编辑（内容实时写回主输入框）
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _ExpandedInputField(
                            initialText: _input.text,
                            // 输入即写回主输入框，返回/收起都不丢内容。
                            onChanged: (value) => _input.text = value,
                          ),
                        ),
                      ),
                      // 内容已实时写回，这里只负责收起。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text('收起'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 删除单条消息：本地移除 + 服务器软删（rawEventId 精确删，保留 7 天可恢复）
  Future<void> _deleteMessage(ChatMessage m) async {
    if (_sending && identical(m, _activeReply)) return; // 流式中不删
    _pendingImageJobs.remove(m);
    _pendingFileJobs.remove(m);
    final hasEventId = (m.eventId ?? '').isNotEmpty;
    final hasEpochId = (m.epochId ?? '').isNotEmpty;
    if (hasEventId != hasEpochId) {
      _showToast('这条消息的服务器身份不完整，先不删除以免历史错位');
      return;
    }
    if (hasEventId && hasEpochId) {
      final deleted = await ChatApi.deleteRuntimeEvent(
        eventId: m.eventId!,
        epochId: m.epochId!,
      );
      if (deleted == null || deleted['ok'] != true) {
        _showToast('服务器暂时没能删除这条消息');
        return;
      }
    }
    final ids = m.rawEventId == null ? null : [m.rawEventId!];
    setState(() => _messages.remove(m));
    await ChatStore.save(_messages);
    if (ids != null && !hasEventId) {
      await ChatApi.deleteIngested(ids);
    }
  }

  /// 图片发送失败占位：点击弹操作菜单（重试发送 / 删除），
  /// 复用 _deleteMessage 的删除逻辑，重试走 _runImageUpload 主链路。
  void _showPendingImageActions(ChatMessage holder) {
    if (holder.imageSendStatus != ImageSendStatus.failed) return;
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        Widget action({
          required IconData icon,
          required Color color,
          required String label,
          required VoidCallback onTap,
        }) {
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              Navigator.pop(ctx);
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [context.cardShadow],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部细把手
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                action(
                  icon: LucideIcons.refresh_cw,
                  color: theme.colorScheme.primary,
                  label: '重新发送',
                  onTap: () => _retryPendingImage(holder),
                ),
                action(
                  icon: LucideIcons.trash_2,
                  color: theme.colorScheme.error,
                  label: '删除消息',
                  onTap: () => _deleteMessage(holder),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 发送失败重试：占位气泡回"发送中"，重新走上传+OCR 链路（不新增消息）。
  void _retryPendingImage(ChatMessage holder) {
    if (_sending || _uploadingImage) return;
    final job = _pendingImageJobs[holder];
    if (job == null) return;
    setState(() {
      _uploadingImage = true;
      holder.imageSendStatus = ImageSendStatus.sending;
      // 只重传失败的单张：成功的标 1 保持，失败的标 0 回发送中
      holder.imageItemStates = [
        for (var i = 0; i < job.items.length; i++) job.urls[i].isEmpty ? 0 : 1,
      ];
    });
    _runImageUpload(holder);
  }

  /// 文件发送失败占位：点卡片弹重试/删除菜单（复用图片占位的交互）。
  void _showPendingFileActions(ChatMessage holder) {
    if (holder.fileSendStatus != FileSendStatus.failed) return;
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        Widget action({
          required IconData icon,
          required Color color,
          required String label,
          required VoidCallback onTap,
        }) {
          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              Navigator.pop(ctx);
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [context.cardShadow],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                action(
                  icon: LucideIcons.refresh_cw,
                  color: theme.colorScheme.primary,
                  label: '重新发送',
                  onTap: () => _retryPendingFile(holder),
                ),
                action(
                  icon: LucideIcons.trash_2,
                  color: theme.colorScheme.error,
                  label: '删除消息',
                  onTap: () => _deleteMessage(holder),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 文件上传失败重试：占位卡片回"发送中"，重新走上传+提取链路（不新增消息）。
  void _retryPendingFile(ChatMessage holder) {
    if (_sending || _uploadingFile) return;
    final job = _pendingFileJobs[holder];
    if (job == null) return;
    setState(() {
      _uploadingFile = true;
      holder.fileSendStatus = FileSendStatus.sending;
    });
    _runFileUpload(holder);
  }

  void _prepareCanonicalCommandUi() {
    _typeTimer?.cancel();
    _typeTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _typingAnim.stop();
    _pending = '';
    _pendingLastDeltaAt = null;
    _pendingIdleTimer?.cancel();
    _pendingIdleTimer = null;
    _pendingRevision = 0;
    _pendingRound = 0;
    _pendingTarget = null;
    _pendingSlot = null;
    _currentSeg = '';
    _currentSegTarget = null;
    _currentSegSlot = null;
    _segments.clear();
    _rawReply = '';
    _thinkingShown = '';
    _thinkingReply = null;
    _replyPresentation.clear();
    _streamDone = false;
    _busy = false;
    _busyRound = 0;
    _termuxRunning = false;
  }

  /// 重新生成：删掉该条 assistant 回复（含服务器软删），把它前面最近的
  /// user 消息重新发一遍（复用 _sendText 主链路）。
  Future<void> _regenerate(ChatMessage assistantMsg) async {
    if (_sending) return;
    final idx = _messages.indexOf(assistantMsg);
    if (idx < 0) return;
    // 找它前面最近的 user 消息
    ChatMessage? prompt;
    for (var i = idx - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        prompt = _messages[i];
        break;
      }
    }
    if (prompt == null) return;
    final hasCanonicalIdentity =
        (prompt.eventId ?? '').isNotEmpty || (prompt.epochId ?? '').isNotEmpty;
    if (hasCanonicalIdentity) {
      if ((prompt.eventId ?? '').isEmpty || (prompt.epochId ?? '').isEmpty) {
        _showToast('这条消息的服务器身份不完整，当前不能安全重新生成');
        return;
      }
      _prepareCanonicalCommandUi();
      final error = await _runtime.startCanonicalRegenerate(
        messages: _messages,
        userMessage: prompt,
      );
      if (mounted && error != null) _showToast(error);
      if (mounted && error == null) _scrollToBottom(force: true);
      return;
    }
    // 删掉 assistantMsg（及它后面可能残留的内容），软删服务器
    final toRemove = <ChatMessage>[assistantMsg];
    final ids = <int>[];
    for (final mm in toRemove) {
      if (mm.rawEventId != null) ids.add(mm.rawEventId!);
    }
    setState(() => _messages.removeWhere(toRemove.contains));
    await ChatStore.save(_messages);
    if (ids.isNotEmpty) await ChatApi.deleteIngested(ids);
    // 重新发送 prompt
    _sendText(prompt.content);
  }

  /// 编辑自己的消息并重发（v0.2.161）：长按 user 消息 → 编辑 → 从这条截断重发。
  /// 借鉴 RikkaHub editMessage（原节点追加同 role 新消息）+
  /// forkConversationAtMessage（subList 到目标节点截断建新会话）；
  /// Continuum Chat单会话流：_messages 截断到编辑条（不含），_sendText 走主链路自己加新条。
  Future<void> _editAndResend(ChatMessage message) async {
    if (_sending) {
      _showToast('AI 助手还在回复，等这轮结束再编辑');
      return;
    }
    final idx = _messages.indexOf(message);
    if (idx < 0) return;
    // 图片/文件消息：编辑文本只当配字，附件字段原样保留重发（审计报告 🟡#4）；
    // 占位 '[图片]'/'[文件]' 不当正文预填进编辑框。
    final isImage =
        (message.imageUrl != null && message.imageUrl!.isNotEmpty) ||
        message.imageUrls.isNotEmpty;
    final isFile = message.fileUrl != null && message.fileUrl!.isNotEmpty;
    var initial = message.content;
    if ((isImage && initial.trim() == '[图片]') ||
        (isFile && initial.trim() == '[文件]')) {
      initial = '';
    }
    final ctrl = TextEditingController(text: initial);
    final edited = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑重发'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(hintText: '改一下再发'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (!mounted || edited == null || edited.trim().isEmpty) return;
    final text = edited.trim();
    final hasCanonicalIdentity =
        (message.eventId ?? '').isNotEmpty ||
        (message.epochId ?? '').isNotEmpty;
    if (hasCanonicalIdentity) {
      if ((message.eventId ?? '').isEmpty || (message.epochId ?? '').isEmpty) {
        _showToast('这条消息的服务器身份不完整，当前不能安全编辑重发');
        return;
      }
      _prepareCanonicalCommandUi();
      final error = await _runtime.startCanonicalEdit(
        messages: _messages,
        target: message,
        editedText: text,
      );
      if (mounted && error != null) _showToast(error);
      if (mounted && error == null) _scrollToBottom(force: true);
      return;
    }
    // legacy 本地历史：截断这条（含）之后的消息，再按旧链路重发。
    setState(() => _messages.removeRange(idx, _messages.length));
    ChatStore.save(_messages);
    if (isImage) {
      _sendText(
        text,
        imageUrl: message.imageUrl,
        ocrText: message.ocrText,
        imageUrls: message.imageUrls,
        imageOcrTexts: message.imageOcrTexts,
      );
    } else if (isFile) {
      _sendText(
        text,
        fileUrl: message.fileUrl,
        fileName: message.fileName,
        fileSize: message.fileSize,
        fileType: message.fileType,
        fileExtractedText: message.fileExtractedText,
      );
    } else {
      _sendText(text);
    }
  }

  void _send() {
    if (_sending || _uploadingImage || _uploadingFile) return;
    final text = _input.text.trim();
    // 有附件（待发图片，多选发图）→ 整批发图流程；否则纯文字
    if (_pendingImages.isNotEmpty) {
      final items = List<_PendingImageItem>.of(_pendingImages);
      setState(() {
        _pendingImages.clear();
      });
      _input.clear();
      _sendImagesWithText(items, text);
      return;
    }
    if (text.isEmpty) return;
    _input.clear();
    _sendText(text);
  }

  /// 快捷消息（v0.2.153）：闪电入口 → 底部列表 → 点一条直接发送。
  /// 列表来自 8816 ~/quick_messages.json（设置页可增删改）；"管理"进管理页。
  Future<void> _openQuickMessages() async {
    if (_sending || _uploadingImage) return;
    final msgs = await ExtensionConfigApi.quickMessages();
    if (mounted && msgs.isNotEmpty) {
      setState(() => _quickMessages = msgs);
    }
    final list = _quickMessages;
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Text(
                    '快捷消息',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, '__manage__'),
                    child: const Text('管理'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          '还没有快捷消息，去设置页加几条',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final msg in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Material(
                          color: ctx.cardColor,
                          borderRadius: BorderRadius.circular(18),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.pop(ctx, msg),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 13,
                              ),
                              child: Text(
                                msg,
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked == '__manage__') {
      await Navigator.of(
        context,
      ).push(SwipeBackRoute(builder: (_) => const QuickMessagesPage()));
      final updated = await ExtensionConfigApi.quickMessages();
      if (mounted && updated.isNotEmpty) {
        setState(() => _quickMessages = updated);
      }
      return;
    }
    _sendText(picked);
  }

  /// 发图片（多选，v0.2.164）：相册多选 → 横排缩略图附加到输入框上方（微信式）
  /// → 点发送整批上传 → 逐张 /ocr 识别 → 合并成一次模型提交（N 张图回一条）。
  /// 单张上限 9 张（防内存爆）；OCR 开关关掉时退回旧行为：只显示图片不发模型。
  Future<void> _pickImage() async {
    if (_sending || _uploadingImage) return;
    try {
      final files = await _picker.pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (files.isEmpty || !mounted) return;
      final items = <_PendingImageItem>[];
      for (final file in files.take(9)) {
        final bytes = await file.readAsBytes();
        final cropped = await _cropPickedImage(bytes);
        if (!mounted) return;
        if (cropped == null) continue;
        items.add(_PendingImageItem(cropped, _croppedImageName(file.name)));
      }
      if (items.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _pendingImages.addAll(items);
      });
    } catch (_) {
      if (mounted) _showToast('选图失败');
    }
  }

  Future<void> _pickCamera() async {
    if (_sending || _uploadingImage) return;
    try {
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      final cropped = await _cropPickedImage(bytes);
      if (!mounted || cropped == null) return;
      setState(() {
        _pendingImages.add(
          _PendingImageItem(cropped, _croppedImageName(file.name)),
        );
      });
    } catch (_) {
      if (mounted) _showToast('拍照失败');
    }
  }

  Future<Uint8List?> _cropPickedImage(Uint8List bytes) async {
    try {
      return await ImageCropService.cropBytes(bytes, title: '裁剪图片');
    } catch (_) {
      if (mounted) _showToast('裁剪失败');
      return null;
    }
  }

  String _croppedImageName(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return '${base}_crop.jpg';
  }

  void _removePendingImageAt(int index) {
    setState(() => _pendingImages.removeAt(index));
  }

  Future<void> _sendImagesWithText(
    List<_PendingImageItem> items,
    String text,
  ) async {
    if (_sending || _uploadingImage) return;
    // 占位气泡：先插进消息流（发出时的时间点），上传期间消息流有反馈
    final holder = ChatMessage(
      role: 'user',
      content: text,
      imageSendStatus: ImageSendStatus.sending,
      imagePreviewBytes: items.first.bytes,
      imagePreviewBytesList: [for (final it in items) it.bytes],
      imageItemStates: List<int>.filled(items.length, 0),
    );
    setState(() {
      _uploadingImage = true;
      _messages.add(holder);
    });
    _pendingImageJobs[holder] = _PendingImageData(items, text);
    _scrollToBottom(force: true);
    await _runImageUpload(holder);
  }

  /// 多选发图上传+OCR 主链路（首次发送/失败重试共用）：
  /// 成功后把占位消息原地升级成真实图片消息（同一条消息对象，位置不变），
  /// 失败时占位气泡转"发送失败"态，可点重试（只重传失败的单张，成功的复用 URL）。
  /// 关键：N 张图的 OCR 合并成一次 _sendText 提交，模型一次看到"发了 N 张图"回一条。
  Future<void> _runImageUpload(ChatMessage holder) async {
    final job = _pendingImageJobs[holder];
    if (job == null) return;
    try {
      final ocrOn = await _ocrEnabled();
      for (var i = 0; i < job.items.length; i++) {
        if (job.urls[i].isNotEmpty) continue; // 已成功的单张不重传
        if (!mounted) return;
        setState(() {
          holder.imageSendStatus = ImageSendStatus.sending;
          holder.imageItemStates = List<int>.of(holder.imageItemStates)
            ..[i] = 0;
        });
        final item = job.items[i];
        final ext = item.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
        final url = await _uploadImage(item.bytes, ext);
        if (!mounted) return;
        if (url == null) {
          setState(() {
            holder.imageItemStates = List<int>.of(holder.imageItemStates)
              ..[i] = 2;
          });
          continue;
        }
        job.urls[i] = url;
        if (ocrOn) {
          job.ocrs[i] = ((await _ocrImage(url)) ?? '').trim();
        }
        if (!mounted) return;
        setState(() {
          holder.imageItemStates = List<int>.of(holder.imageItemStates)
            ..[i] = 1;
        });
      }
      if (!mounted) return;
      final anyFailed = job.urls.any((u) => u.isEmpty);
      if (anyFailed) {
        // 部分失败：保持失败占位，点重试只补传失败的单张
        setState(() {
          _uploadingImage = false;
          holder.imageSendStatus = ImageSendStatus.failed;
        });
        _showToast('部分图片没发出去，点图片重试');
        return;
      }
      setState(() => _uploadingImage = false);
      if (ocrOn) {
        // 合并 OCR 一次提交：N 张图的 URL+OCR 全给模型，模型回一条
        _sendText(
          job.text.isEmpty ? '[图片]' : job.text,
          imageUrls: List<String>.of(job.urls),
          imageOcrTexts: List<String>.of(job.ocrs),
          attachTo: holder,
        );
      } else {
        // OCR 开关关：只显示图，不发模型
        setState(() {
          holder
            ..content = job.text
            ..imageUrls = List<String>.of(job.urls)
            ..imageOcrTexts = List<String>.of(job.ocrs)
            ..imageSendStatus = null
            ..imagePreviewBytes = null
            ..imagePreviewBytesList = []
            ..imageItemStates = [];
        });
        _pendingImageJobs.remove(holder);
        ChatStore.save(_messages);
        _scrollToBottom();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uploadingImage = false;
        holder.imageSendStatus = ImageSendStatus.failed;
      });
      _showToast('图片没发出去，请重试');
    }
  }

  /// 加号按钮：系统文件选择（Android 原生 Intent，MethodChannel），
  /// 选完弹底部预览（文件图标+文件名+大小+配字可选）→ 确认后上传。
  Future<void> _pickFile() async {
    if (_sending || _uploadingImage || _uploadingFile) return;
    try {
      final file = await FilePickerApi.pick();
      if (!mounted || file == null) return;
      await _showFilePreview(file);
    } on PlatformException catch (e) {
      if (mounted) _showToast(e.message ?? '选文件失败');
    } catch (_) {
      if (mounted) _showToast('选文件失败');
    }
  }

  /// 文件预览确认（底部弹层）：图标+文件名+大小 + 配字输入框 + 取消/发送。
  Future<void> _showFilePreview(PickedLocalFile file) async {
    final ctrl = TextEditingController();
    final theme = Theme.of(context);
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [context.cardShadow],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      file.type == 'audio'
                          ? LucideIcons.file_music
                          : file.type == 'image'
                          ? LucideIcons.file_image
                          : LucideIcons.file_text,
                      size: 26,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatFileSizeText(file.size),
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: false,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: '说点什么（可选）',
                    filled: true,
                    fillColor: context.fieldColor,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('发送'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (!mounted || sent != true) return;
    _sendFileWithText(file, text);
  }

  /// 文件发送入口：占位文件卡片（上传中）→ 上传 + 服务端提取文本 →
  /// 原地升级成真实文件消息，提取文本拼进模型上下文一次提交。
  Future<void> _sendFileWithText(PickedLocalFile file, String text) async {
    if (_sending || _uploadingFile) return;
    final holder = ChatMessage(
      role: 'user',
      content: text.isEmpty ? '[文件]' : text,
      fileName: file.name,
      fileSize: file.size,
      fileType: file.type,
      fileSendStatus: FileSendStatus.sending,
    );
    setState(() {
      _uploadingFile = true;
      _messages.add(holder);
    });
    _pendingFileJobs[holder] = _PendingFileData(
      file.path,
      file.name,
      file.size,
      file.type,
      text,
    );
    _scrollToBottom(force: true);
    await _runFileUpload(holder);
  }

  /// 文件上传主链路（首次发送/失败重试共用）：流式上传（不 base64 进内存），
  /// 服务器响应里带自动提取文本（文档解析/原图 OCR/音频 ASR）。
  Future<void> _runFileUpload(ChatMessage holder) async {
    final job = _pendingFileJobs[holder];
    if (job == null) return;
    try {
      final res = await _uploadFileToServer(job);
      if (!mounted) return;
      if (res == null) {
        setState(() {
          _uploadingFile = false;
          holder.fileSendStatus = FileSendStatus.failed;
        });
        _showToast('文件没发出去，请检查网络后重试');
        return;
      }
      setState(() => _uploadingFile = false);
      _pendingFileJobs.remove(holder);
      // 占位原地升级成真实文件卡片消息；提取文本随 _sendText 给模型
      _sendText(
        job.text.isEmpty ? '[文件]' : job.text,
        fileUrl: res.url,
        fileName: res.name,
        fileSize: res.size,
        fileType: res.type,
        fileExtractedText: res.text,
        attachTo: holder,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uploadingFile = false;
        holder.fileSendStatus = FileSendStatus.failed;
      });
      _showToast('文件没发出去，请重试');
    }
  }

  /// 流式上传到 8816 /files：raw 二进制 + X-File-Name/X-File-Size 头，
  /// 大文件不 base64 不整读内存；返回 URL/提取文本等，失败 null。
  Future<_FileUploadResult?> _uploadFileToServer(_PendingFileData job) async {
    final client = http.Client();
    try {
      final file = File(job.path);
      final size = await file.length();
      final req = http.StreamedRequest(
        'POST',
        Uri.parse(ServerConfig.url(8816, '/files')),
      );
      req.headers.addAll(
        ChatApi.authHeaders({
          'X-File-Name': Uri.encodeComponent(job.name),
          'X-File-Size': '$size',
        }),
      );
      req.contentLength = size;
      unawaited(
        req.sink.addStream(file.openRead()).then((_) => req.sink.close()),
      );
      final resp = await client.send(req).timeout(const Duration(seconds: 180));
      final body = await resp.stream.bytesToString();
      if (resp.statusCode == 200) {
        final j = jsonDecode(body) as Map<String, dynamic>;
        return _FileUploadResult(
          url: j['url'] as String? ?? '',
          name: j['name'] as String? ?? job.name,
          size: (j['size'] as num?)?.toInt() ?? size,
          type: j['type'] as String? ?? job.type,
          text: j['text'] as String? ?? '',
        );
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static String _formatFileSizeText(int size) {
    if (size <= 0) return '未知大小';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  /// OCR 开关：配置中心 → OCR → 图片识别（默认开，开才走识别+发模型）。
  Future<bool> _ocrEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('ocr_enabled') ?? true;
  }

  /// 调服务器 /ocr 识别图片内容（POST {url} → {text}），失败返回 null。
  Future<String?> _ocrImage(String url) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/ocr')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'url': url}),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        return j['text'] as String?;
      }
    } catch (_) {
      // 识别失败不阻塞发送（图还是会显示）
    }
    return null;
  }

  /// 上传图片到服务器，返回 URL（失败返回 null）。
  Future<String?> _uploadImage(Uint8List bytes, String ext) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/upload')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'data': base64Encode(bytes), 'ext': ext}),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        return j['url'] as String?;
      }
    } catch (_) {
      // 网络失败
    }
    return null;
  }

  /// 真正发送一条 user 消息（_send 和"重新生成"共用主链路）。
  /// [imageUrl] 图片消息：气泡显示图片，content 已拼入 [我发了一张图：URL]+OCR 结果供模型"看到"。
  /// [attachTo] 图片占位消息：传入时原地升级成真实图片消息（保持原位置不跳位），
  /// 不新增消息；否则按旧逻辑新加一条 user 消息。
  void _sendText(
    String text, {
    String? imageUrl,
    String? ocrText,
    List<String>? imageUrls,
    List<String>? imageOcrTexts,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? fileType,
    String? fileExtractedText,
    ChatMessage? attachTo,
    String? eventId,
    String? clientEventId,
    String? generationId,
    String? epochId,
  }) {
    _pending = '';
    _pendingLastDeltaAt = null;
    _pendingIdleTimer?.cancel();
    _pendingIdleTimer = null;
    _pendingRevision = 0;
    _pendingRound = 0;
    _pendingTarget = null;
    _pendingSlot = null;
    _rawReply = '';
    _currentSeg = '';
    _currentSegTarget = null;
    _currentSegSlot = null;
    _segments.clear();
    _pausing = false;
    _streamDone = false;
    _busy = false;
    _busyRound = 0;
    _termuxRunning = false;
    _pauseTimer?.cancel();
    _typeTimer?.cancel();
    _typeTimer = null;
    _thinkingShown = '';
    _thinkingReply = null;
    _replyPresentation.clear();

    late final ChatMessage sentMessage;
    setState(() {
      if (attachTo != null) {
        // 图片/文件占位气泡原地升级为真实消息（同一条对象，位置不动）
        sentMessage = attachTo;
        attachTo
          ..content = text
          ..imageUrl = imageUrl
          ..ocrText = ocrText
          ..imageUrls = imageUrls ?? const []
          ..imageOcrTexts = imageOcrTexts ?? const []
          ..fileUrl = fileUrl
          ..fileExtractedText = fileExtractedText
          ..eventId = eventId
          ..clientEventId = clientEventId
          ..generationId = generationId
          ..epochId = epochId
          ..imageSendStatus = null
          ..fileSendStatus = null
          ..sendFailed = false
          ..sendError = null
          ..imagePreviewBytes = null
          ..imagePreviewBytesList = []
          ..imageItemStates = [];
      } else {
        sentMessage = ChatMessage(
          role: 'user',
          content: text,
          imageUrl: imageUrl,
          ocrText: ocrText,
          imageUrls: imageUrls ?? const [],
          imageOcrTexts: imageOcrTexts ?? const [],
          fileUrl: fileUrl,
          fileName: fileName,
          fileSize: fileSize,
          fileType: fileType,
          fileExtractedText: fileExtractedText,
          eventId: eventId,
          clientEventId: clientEventId,
          generationId: generationId,
          epochId: epochId,
        );
        _messages.add(sentMessage);
      }
      _sending = true;
      _typing = false;
    });
    _pendingImageJobs.remove(attachTo);
    _pendingFileJobs.remove(attachTo);
    ChatStore.save(_messages);
    _scrollToBottom(force: true);

    // 预留一个空的 assistant 消息占位，流式填充
    final reply = ChatMessage(role: 'assistant', content: '');
    _activeReply = reply;
    setState(() => _messages.add(reply));

    // 上下文无限制：带当前窗口全部非空消息（空占位是流式回复的填充位，不带上；
    // 发送中/失败占位是瞬态，也没发出去，不注入模型）
    final history = _messages
        .where(
          (m) =>
              m.content.isNotEmpty &&
              !m.sendFailed &&
              m.imageSendStatus == null &&
              m.fileSendStatus == null,
        )
        .toList();

    unawaited(
      _runtime.startChat(
        messages: _messages,
        history: history,
        sentMessage: sentMessage,
        reply: reply,
      ),
    );
  }

  Widget _buildScrollJumpButtons(ThemeData theme) {
    final visible = _showScrollJumpButtons && _messages.isNotEmpty;
    final dividerColor = theme.colorScheme.outlineVariant.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.34 : 0.42,
    );
    final foreground = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.9,
    );
    final background = theme.colorScheme.surface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.94 : 0.97,
    );
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Container(
          width: 44,
          height: 89,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.18 : 0.08,
                ),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(21.2),
            child: Column(
              children: [
                _buildScrollJumpButton(
                  theme,
                  icon: LucideIcons.chevron_up,
                  tooltip: '回到顶部',
                  foreground: foreground,
                  onPressed: _scrollChatListToTop,
                ),
                Container(height: 1, width: 22, color: dividerColor),
                _buildScrollJumpButton(
                  theme,
                  icon: LucideIcons.chevron_down,
                  tooltip: '回到底部',
                  foreground: foreground,
                  onPressed: _scrollChatListToBottom,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollJumpButton(
    ThemeData theme, {
    required IconData icon,
    required String tooltip,
    required Color foreground,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          foregroundColor: foreground,
          minimumSize: const Size(44, 44),
          maximumSize: const Size(44, 44),
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          overlayColor: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        ),
        icon: Icon(icon, size: 18),
      ),
    );
  }

  Widget _buildComposer(ThemeData theme) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => ListenableBuilder(
        listenable: _inputFocus,
        builder: (context, _) {
          final hasText = value.text.trim().isNotEmpty;
          final hasContent = hasText || _pendingImages.isNotEmpty;
          final controlsDisabled =
              _sending || _uploadingImage || _uploadingFile;
          final composerColor = context.cardColor;

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Container(
              decoration: BoxDecoration(
                color: composerColor,
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: [context.cardShadow],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_pendingImages.isNotEmpty)
                      _buildPendingImageStrip(theme),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: TextField(
                              controller: _input,
                              focusNode: _inputFocus,
                              minLines: 1,
                              maxLines: 5,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              scrollPadding: const EdgeInsets.only(bottom: 96),
                              style: TextStyle(
                                fontSize: 15.5,
                                height: 1.45,
                                color: theme.colorScheme.onSurface,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                filled: false,
                                hintText: '跟AI 助手说点什么…',
                                hintStyle: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.52),
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  6,
                                  10,
                                ),
                              ),
                            ),
                          ),
                        ),
                        _buildComposerToolButton(
                          theme,
                          icon: LucideIcons.chevrons_up_down,
                          tooltip: '展开编辑',
                          onPressed: _openInputEditor,
                        ),
                        const SizedBox(width: 4),
                        _buildSendButton(theme, hasContent: hasContent),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 2, 50, 0),
                      child: Row(
                        children: [
                          _buildComposerToolButton(
                            theme,
                            icon: LucideIcons.zap,
                            tooltip: '快捷消息',
                            onPressed: controlsDisabled
                                ? null
                                : _openQuickMessages,
                          ),
                          _buildComposerToolButton(
                            theme,
                            icon: LucideIcons.image,
                            tooltip: '选图片',
                            loading: _uploadingImage,
                            onPressed: controlsDisabled ? null : _pickImage,
                          ),
                          _buildComposerToolButton(
                            theme,
                            icon: LucideIcons.camera,
                            tooltip: '拍照',
                            onPressed: controlsDisabled ? null : _pickCamera,
                          ),
                          _buildComposerToolButton(
                            theme,
                            icon: LucideIcons.plus,
                            tooltip: '发文件',
                            loading: _uploadingFile,
                            onPressed: controlsDisabled ? null : _pickFile,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPendingImageStrip(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
      child: SizedBox(
        height: 72,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: _pendingImages.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(
                  _pendingImages[i].bytes,
                  height: 64,
                  width: 64,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                right: -12,
                top: -12,
                child: SizedBox.square(
                  dimension: 44,
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () => _removePendingImageAt(i),
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            shape: BoxShape.circle,
                            boxShadow: [context.cardShadow],
                          ),
                          child: Icon(
                            LucideIcons.x,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComposerToolButton(
    ThemeData theme, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool loading = false,
  }) {
    final color = theme.colorScheme.onSurfaceVariant;
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        onPressed: loading ? null : onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: color.withValues(alpha: 0.36),
          minimumSize: const Size(44, 44),
          maximumSize: const Size(44, 44),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const CircleBorder(),
        ),
        icon: loading
            ? SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color.withValues(alpha: 0.7),
                ),
              )
            : Icon(icon, size: 20),
      ),
    );
  }

  Widget _buildSendButton(ThemeData theme, {required bool hasContent}) {
    final busy = _uploadingImage || _uploadingFile;
    final state = _sending
        ? ChatComposerRuntimeState.active
        : _presentationDraining
        ? ChatComposerRuntimeState.draining
        : ChatComposerRuntimeState.idle;
    return ChatComposerSendButton(
      state: state,
      hasContent: hasContent,
      busy: busy,
      onSend: _send,
    );
  }

  double _messageTopGap(ChatMessage message, ChatMessage? previous) {
    if (previous == null) return 6;
    if (_isStatusLikeMessage(message) || _isStatusLikeMessage(previous)) {
      return 12;
    }
    if (message.role == previous.role) return 4;
    return 12;
  }

  double _messageBottomGap(ChatMessage message, {required bool isLast}) {
    if (isLast) return 12;
    return _isStatusLikeMessage(message) ? 2 : 1;
  }

  bool _isStatusLikeMessage(ChatMessage message) =>
      message.isActivity || message.isToolDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _handleKeyboardInset(MediaQuery.viewInsetsOf(context).bottom);
    // Android 返回键：抽屉开着时按返回只关抽屉不退出，关着才允许正常返回。
    // AnimatedBuilder 监听 _drawerCtrl，让 canPop 随抽屉动画实时更新（否则一直是初值）
    return AnimatedBuilder(
      animation: _drawerCtrl,
      builder: (context, child) => PopScope(
        canPop: _drawerCtrl.value <= 0.01,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _drawerCtrl.value > 0.01) {
            _closeDrawer();
          }
        },
        child: child!,
      ),
      child: GestureDetector(
        // 全屏横向拖动拉抽屉：先过方向/位移阈值，再跟手接管。
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _handleDrawerDragStart,
        onHorizontalDragUpdate: (details) =>
            _handleDrawerDragUpdate(context, details),
        onHorizontalDragEnd: _handleDrawerDragEnd,
        onHorizontalDragCancel: _handleDrawerDragCancel,
        child: Stack(
          children: [
            Scaffold(
              key: _scaffoldKey,
              // edge-to-edge 下手动处理键盘：关闭系统 resize，用 viewInsets padding 顶起输入区
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                toolbarHeight: 56,
                titleSpacing: 16,
                backgroundColor: theme.colorScheme.surface,
                foregroundColor: theme.colorScheme.onSurface,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                iconTheme: IconThemeData(
                  size: 21,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                actionsIconTheme: IconThemeData(
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                // "正在输入中…"嵌在标题下方，和名字一体，没有单独底色
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 昵称（抽屉可改名，全局生效）
                    ListenableBuilder(
                      listenable: NicknameManager.instance,
                      builder: (context, _) => Text(
                        NicknameManager.instance.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (_typing)
                      AnimatedBuilder(
                        animation: _typingAnim,
                        builder: (context, _) => _buildTypingRow(theme),
                      ),
                  ],
                ),
                centerTitle: false,
                elevation: 0,
                scrolledUnderElevation: 0,
                actions: [
                  const ChatSceneModeControl(),
                  IconButton(
                    icon: const Icon(LucideIcons.search, size: 20),
                    tooltip: '搜索消息',
                    onPressed: _openSearch,
                  ),
                ],
              ),
              body: Padding(
                // 键盘弹出时底部加键盘高度，输入区被顶起、消息列表完整露出（方案2，v0.2.22）
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _messages.isEmpty
                          ? const ChatEmptyState()
                          : Stack(
                              children: [
                                NotificationListener<ScrollNotification>(
                                  onNotification:
                                      _handleMessageScrollNotification,
                                  child: ListView.builder(
                                    controller: _scroll,
                                    reverse: true,
                                    padding: EdgeInsets.fromLTRB(
                                      12,
                                      10,
                                      12,
                                      _composerHeight + 8,
                                    ),
                                    itemCount:
                                        _messages.length +
                                        (((_busy || _termuxRunning) &&
                                                _busyRound <= 0)
                                            ? 1
                                            : 0),
                                    itemBuilder: (context, i) {
                                      // v0.2.118：shell 执行中 → 对话流末尾加
                                      // "AI 助手在忙… N"居中低调小气泡（round >= 2 显示轮次数字，
                                      // 样式照 activity 卡片）；v0.2.153：Termux 桥接执行中
                                      // 文案换成"AI 助手在手机上操作…"。
                                      // v0.2.168：执行完占位不消失，变成"✓ 搞定了！"
                                      // 永久记录（作为 tool_done 消息留在 _messages 里）
                                      // v0.2.169：只有心跳静默工具（round==0）还走
                                      // 列表末尾占位；正在流式回复的工具状态改嵌进
                                      // 该回复内部的时间线（下面 _buildReplyTimeline）。
                                      if ((_busy || _termuxRunning) &&
                                          _busyRound <= 0 &&
                                          i == 0) {
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 12,
                                          ),
                                          child: MessageBubble.busyCard(
                                            theme,
                                            label: _busyLabel,
                                          ),
                                        );
                                      }
                                      final busyOffset =
                                          ((_busy || _termuxRunning) &&
                                              _busyRound <= 0)
                                          ? 1
                                          : 0;
                                      final messageIndex =
                                          _messages.length -
                                          1 -
                                          (i - busyOffset);
                                      final m = _messages[messageIndex];
                                      final previousMessage = messageIndex > 0
                                          ? _messages[messageIndex - 1]
                                          : null;
                                      final prev = previousMessage?.time;
                                      // v0.2.95 思考链独立成对话流：带思考的消息渲染成
                                      // 独立行交替排列：思考气泡 → 正文气泡。
                                      // v0.2.121：多轮思考——reasonings 每轮一条
                                      // （index = round-1），每轮渲染一个独立思考气泡，
                                      // 轮次分明；老消息只有单字段 reasoning 按单轮处理。
                                      // 思考气泡无头像，左缘缩进对齐正文气泡（_kThinkingInset）
                                      // v0.2.169：一条回复内部按真实时间顺序穿插渲染
                                      // 「思考1 → 工具状态 → 思考2 → 正文」，工具完成
                                      // 轮次记在 m.toolDoneRounds 上，不再独立成消息。
                                      final isActiveReply = identical(
                                        m,
                                        _activeReply,
                                      );
                                      final streamingThisReply =
                                          isActiveReply ||
                                          _presentationPendingFor(m) ||
                                          _thinkingReply == m;
                                      Widget row;
                                      if (m.role == 'assistant' &&
                                          m.parts.isNotEmpty) {
                                        row = _buildPartsMessage(
                                          theme,
                                          m,
                                          prev,
                                          streaming: streamingThisReply,
                                          previousUserText:
                                              previousMessage?.role == 'user'
                                              ? previousMessage?.content
                                              : null,
                                        );
                                      } else {
                                        final waitingContent =
                                            _sending &&
                                            isActiveReply &&
                                            m.content.isEmpty;
                                        final rounds = m.reasonings.isNotEmpty
                                            ? List<String>.of(m.reasonings)
                                            : (m.reasoning.isNotEmpty
                                                  ? <String>[m.reasoning]
                                                  : const <String>[]);
                                        final doneRounds = m.toolDoneRounds
                                            .toSet();
                                        // busy 属于这条正在流式的回复时嵌进它内部；
                                        // round == 0 是心跳静默工具，走上面的列表末尾占位
                                        final inlineBusy =
                                            (_busy || _termuxRunning) &&
                                            _busyRound > 0 &&
                                            streamingThisReply;
                                        final showThinking =
                                            rounds.isNotEmpty ||
                                            doneRounds.isNotEmpty ||
                                            inlineBusy;
                                        row = _buildMessageRow(theme, m, prev);
                                        if (showThinking) {
                                          final timeline = _buildReplyTimeline(
                                            m,
                                            rounds: rounds,
                                            doneRounds: doneRounds,
                                            streaming: streamingThisReply,
                                            waitingContent: waitingContent,
                                            inlineBusy: inlineBusy,
                                          );
                                          row = Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              // 思考/工具状态按真实时间顺序穿插
                                              timeline,
                                              // 时间线与正文气泡间距（比普通消息间距略大）
                                              const SizedBox(height: 6),
                                              // 正文气泡（带头像，原样）
                                              row,
                                            ],
                                          );
                                        }
                                      }
                                      Widget bubble = AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        decoration: BoxDecoration(
                                          color: messageIndex == _focusIndex
                                              ? context.processColor
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: Padding(
                                          padding: EdgeInsets.only(
                                            left: 4,
                                            right: 4,
                                            top: _messageTopGap(
                                              m,
                                              previousMessage,
                                            ),
                                            bottom: _messageBottomGap(
                                              m,
                                              isLast:
                                                  messageIndex ==
                                                      _messages.length - 1 &&
                                                  !((_busy || _termuxRunning) &&
                                                      _busyRound <= 0),
                                            ),
                                          ),
                                          child: row,
                                        ),
                                      );
                                      // 搜索结果定位：目标条构建后精确滚动到可视区
                                      if (messageIndex == _focusIndex &&
                                          _focusPending) {
                                        bubble = Builder(
                                          builder: (ctx) {
                                            WidgetsBinding.instance
                                                .addPostFrameCallback((_) {
                                                  if (!mounted ||
                                                      !_focusPending) {
                                                    return;
                                                  }
                                                  Scrollable.ensureVisible(
                                                    ctx,
                                                    duration: const Duration(
                                                      milliseconds: 400,
                                                    ),
                                                    curve: Curves.easeOutCubic,
                                                    alignment: 0.35,
                                                  );
                                                  setState(
                                                    () => _focusPending = false,
                                                  );
                                                  _focusTimer?.cancel();
                                                  _focusTimer = Timer(
                                                    const Duration(seconds: 3),
                                                    () {
                                                      if (mounted) {
                                                        setState(
                                                          () => _focusIndex =
                                                              null,
                                                        );
                                                      }
                                                    },
                                                  );
                                                });
                                            return bubble;
                                          },
                                        );
                                      }
                                      return bubble;
                                    },
                                  ),
                                ),
                                Positioned(
                                  right: 12,
                                  bottom: _composerHeight + 12,
                                  child: _buildScrollJumpButtons(theme),
                                ),
                              ],
                            ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _MeasureSize(
                        onChange: (size) {
                          if (!mounted ||
                              (size.height - _composerHeight).abs() < 0.5) {
                            return;
                          }
                          setState(() => _composerHeight = size.height);
                        },
                        child: SafeArea(
                          top: false,
                          child: _buildComposer(theme),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 遮罩层：抽屉打开时半透明压住主内容，点遮罩关闭
            AnimatedBuilder(
              animation: _drawerCtrl,
              builder: (context, _) {
                return Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _drawerCtrl.value <= 0.01,
                    child: GestureDetector(
                      onTap: _closeDrawer,
                      child: Container(
                        color: context.scrimColor.withValues(
                          alpha: 0.35 * _drawerCtrl.value,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 抽屉层：跟手，位置由 controller 驱动（0 藏左外 / 1 全开）
            AnimatedBuilder(
              animation: _drawerCtrl,
              builder: (context, _) {
                // 抽屉宽度：屏宽 80%，不超过 360px（RikkaHub 式）
                final width = _drawerWidthFor(context);
                return Positioned(
                  left: -width + _drawerCtrl.value * width,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: Material(
                    elevation: 16,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(20),
                    ),
                    color: theme.colorScheme.surface,
                    clipBehavior: Clip.antiAlias,
                    child: OverviewDrawer(
                      onStartNewChat: _startNewChat,
                      onOpenHistory: _openHistory,
                      onOpenMemory: _openMemory,
                      onOpenAssistant: _openAssistant,
                      onOpenTogether: _openTogether,
                      onOpenAbility: _openAbility,
                      onOpenSettings: _openSettings,
                      onClose: _closeDrawer,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // 消息行：v0.2.96 起头像移进 MessageBubble，每个段落气泡各配一个
  // （AI 助手左/用户右），这里直接渲染整条消息；思考气泡由上方 ThinkingCard 承载、无头像。
  Widget _buildMessageRow(ThemeData theme, ChatMessage m, DateTime? prev) {
    // tool_done：工具执行完成的"✓ 搞定了！"固定记录（样式同 busy 占位，永久保留；
    // 必须先于 isActivity 判断——tool_done 同走纯展示管线）
    if (m.isToolDone) {
      return MessageBubble.toolDoneCard(theme, label: m.content);
    }
    // activity 消息：居中低调小卡片，不走普通气泡/头像/思考链
    if (m.isActivity) {
      return ValueListenableBuilder<bool>(
        valueListenable: TimestampPref.show,
        builder: (context, showTimestamp, _) => MessageBubble.activityCard(
          theme,
          m,
          prev,
          showTimestamp: showTimestamp,
        ),
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: TimestampPref.show,
      builder: (context, showTimestamp, _) => ValueListenableBuilder<bool>(
        valueListenable: TokenUsagePref.show,
        builder: (context, showUsage, _) => MessageBubble(
          message: m,
          isMe: m.role == 'user',
          prevTime: prev,
          // 正在流式输出的消息：时间戳发完才显示（思考链已挪到上方卡片）
          streaming:
              (_activeReply != null && identical(m, _activeReply)) ||
              _presentationPendingFor(m),
          // 长按操作（合并进系统选择工具栏；流式中禁删）
          onCopyAll: () {
            Clipboard.setData(ClipboardData(text: m.content));
            _showToast(m.content.isEmpty ? '没有内容' : '已复制');
          },
          onRegenerate: m.role == 'assistant' && !_sending
              ? () => _regenerate(m)
              : null,
          // 编辑重发（仅自己的 user 消息；流式中先提示停止）
          onEdit: m.role == 'user' ? () => _editAndResend(m) : null,
          onDelete: _sending && identical(m, _activeReply)
              ? null
              : () => _deleteMessage(m),
          // 图片发送失败占位：点击弹重试/删除菜单
          onImageSendTap: m.imageSendStatus == ImageSendStatus.failed
              ? () => _showPendingImageActions(m)
              : null,
          // 文件发送失败占位：点击弹重试/删除菜单
          onFileSendTap: m.fileSendStatus == FileSendStatus.failed
              ? () => _showPendingFileActions(m)
              : null,
          onSendFailedTap: m.sendFailed ? () => _restoreFailedMessage(m) : null,
          showTokenUsage: showUsage,
          showTimestamp: showTimestamp,
        ),
      ),
    );
  }

  Widget _buildPartsMessage(
    ThemeData theme,
    ChatMessage m,
    DateTime? prev, {
    required bool streaming,
    String? previousUserText,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: TimestampPref.show,
      builder: (context, showTimestamp, _) => ValueListenableBuilder<bool>(
        valueListenable: TokenUsagePref.show,
        builder: (context, showUsage, _) => ValueListenableBuilder<bool>(
          valueListenable: ReasoningPref.show,
          builder: (context, showReasoning, _) => _buildPartsMessageBody(
            theme,
            m,
            prev,
            streaming: streaming,
            showTimestamp: showTimestamp,
            showTokenUsage: showUsage,
            showReasoning: showReasoning,
            previousUserText: previousUserText,
          ),
        ),
      ),
    );
  }

  Widget _buildPartsMessageBody(
    ThemeData theme,
    ChatMessage m,
    DateTime? prev, {
    required bool streaming,
    required bool showTimestamp,
    required bool showTokenUsage,
    required bool showReasoning,
    String? previousUserText,
  }) {
    final visible = <Widget>[];
    var renderedBubbleCount = 0;
    final presentedParts = suppressExactUserEchoInterimParts(
      _replyPresentation.projectedParts(m),
      previousUserText: previousUserText,
    );
    final lastTextPartIndex = presentedParts.lastIndexWhere(
      (part) =>
          part.type == ChatMessagePartType.text && part.text.trim().isNotEmpty,
    );
    final lastVisiblePartIndex = presentedParts.lastIndexWhere(
      (part) =>
          (part.type == ChatMessagePartType.text &&
              part.text.trim().isNotEmpty) ||
          (part.type == ChatMessagePartType.image && part.url.isNotEmpty),
    );
    final timeline = buildChatPartTimeline(
      presentedParts,
      showReasoning: showReasoning,
    );
    final activeProcessEndIndex =
        streaming &&
            timeline.isNotEmpty &&
            timeline.last.type == ChatPartTimelineItemType.process
        ? timeline.last.section?.endIndex ?? -1
        : -1;
    for (final item in timeline) {
      Widget? child;
      switch (item.type) {
        case ChatPartTimelineItemType.process:
          final section = item.section;
          if (section == null) break;
          child = _buildProcessSectionBubble(
            m,
            section,
            streaming: streaming,
            showReasoning: showReasoning,
            active: section.endIndex == activeProcessEndIndex,
          );
        case ChatPartTimelineItemType.part:
          final ref = item.part;
          if (ref == null) break;
          final part = ref.part;
          switch (part.type) {
            case ChatMessagePartType.text:
              final carriesUsage =
                  lastTextPartIndex >= 0 &&
                  ref.index == lastTextPartIndex &&
                  m.usage != null;
              if (part.text.trim().isEmpty) break;
              final temp = ChatMessage(
                role: 'assistant',
                content: part.text,
                time: m.time,
                runtimeStatus: ref.index == lastVisiblePartIndex
                    ? m.runtimeStatus
                    : null,
                usage: carriesUsage ? m.usage : null,
              );
              child = MessageBubble(
                message: temp,
                isMe: false,
                prevTime: renderedBubbleCount == 0 ? prev : null,
                streaming: streaming,
                onCopyAll: () {
                  Clipboard.setData(ClipboardData(text: part.text));
                  _showToast(part.text.isEmpty ? '没有内容' : '已复制');
                },
                onRegenerate: !_sending ? () => _regenerate(m) : null,
                onDelete: _sending && identical(m, _activeReply)
                    ? null
                    : () => _deleteMessage(m),
                showTokenUsage: showTokenUsage,
                showTimestamp: showTimestamp,
              );
              renderedBubbleCount += 1;
            case ChatMessagePartType.image:
              if (part.url.isEmpty) break;
              final temp = ChatMessage(
                role: 'assistant',
                content: '',
                imageUrl: part.url,
                time: m.time,
                runtimeStatus: ref.index == lastVisiblePartIndex
                    ? m.runtimeStatus
                    : null,
              );
              child = MessageBubble(
                message: temp,
                isMe: false,
                prevTime: renderedBubbleCount == 0 ? prev : null,
                streaming: streaming,
                onCopyAll: () {
                  Clipboard.setData(ClipboardData(text: part.url));
                  _showToast('已复制');
                },
                onRegenerate: !_sending ? () => _regenerate(m) : null,
                onDelete: _sending && identical(m, _activeReply)
                    ? null
                    : () => _deleteMessage(m),
                showTimestamp: showTimestamp,
              );
              renderedBubbleCount += 1;
            case ChatMessagePartType.reasoning:
              if (!showReasoning) break;
              final active =
                  streaming &&
                  (part.status == 'running' || part.status == 'streaming');
              final text = part.text.isNotEmpty ? part.text : part.delta;
              if (text.trim().isEmpty && !active) break;
              child = _buildThinkingCard(
                m,
                round: part.round <= 0 ? 1 : part.round,
                text: text,
                active: active,
              );
            case ChatMessagePartType.tool:
              break;
          }
      }
      if (child == null) continue;
      if (visible.isNotEmpty) visible.add(const SizedBox(height: 6));
      visible.add(child);
    }
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: visible,
    );
  }

  String _processSectionTitle(
    ChatProcessSection section, {
    required bool showReasoning,
    required bool active,
  }) {
    final names = <String>[];
    for (final step in section.steps) {
      if (step.part.type != ChatMessagePartType.tool) continue;
      for (final name in _toolNames(step.part)) {
        if (!names.contains(name)) names.add(name);
      }
    }
    return chatProcessSectionLabel(
      failed: section.isFailed,
      active: active,
      hasTool: section.hasTool,
      stepCount: section.visibleStepCount(showReasoning: showReasoning),
      toolNames: names,
    );
  }

  Widget _buildProcessSectionBubble(
    ChatMessage message,
    ChatProcessSection section, {
    required bool streaming,
    required bool showReasoning,
    required bool active,
  }) {
    final theme = Theme.of(context);
    final sectionActive = !section.isFailed && active;
    if (!section.hasTool) {
      final reasoningSteps = section
          .visibleSteps(showReasoning: showReasoning)
          .where((step) => step.part.type == ChatMessagePartType.reasoning)
          .toList();
      final text = reasoningSteps
          .map(
            (step) => step.part.text.isNotEmpty
                ? step.part.text.trim()
                : step.part.delta.trim(),
          )
          .where((value) => value.isNotEmpty)
          .join('\n\n');
      final firstRound = reasoningSteps.isEmpty
          ? 1
          : (reasoningSteps.first.part.round <= 0
                ? 1
                : reasoningSteps.first.part.round);
      return _buildThinkingCard(
        message,
        round: firstRound,
        text: text,
        active: sectionActive,
      );
    }
    final key = _processSectionKey(message, section);
    final expanded = _expandedProcessSections.contains(key);
    if (sectionActive && !_typingAnim.isAnimating) {
      _typingAnim.repeat();
    }
    final label = _processSectionTitle(
      section,
      showReasoning: showReasoning,
      active: sectionActive,
    );
    final icon = section.isFailed
        ? LucideIcons.circle_alert
        : section.hasTool
        ? LucideIcons.ellipsis
        : LucideIcons.brain;
    return Padding(
      padding: const EdgeInsets.only(left: _kThinkingInset),
      child: _ReportLayoutExtent(
        onLayout: (extent) {
          _processSectionExtents[key] = extent;
          _scroll.reportAnchorExtent(key, extent);
        },
        child: Container(
          constraints: BoxConstraints(
            minHeight: 32,
            maxWidth: MediaQuery.of(context).size.width * 0.76,
          ),
          decoration: BoxDecoration(
            color: context.processColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    splashColor: theme.colorScheme.primary.withValues(
                      alpha: 0.05,
                    ),
                    highlightColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.04,
                    ),
                    onTap: () => _toggleProcessSection(key),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            icon,
                            size: 14,
                            color: section.isFailed
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            expanded
                                ? LucideIcons.chevron_up
                                : LucideIcons.chevron_down,
                            size: 14,
                            color: theme.colorScheme.outline,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (expanded) ...[
                    _buildProcessSectionBody(
                      theme,
                      message,
                      section,
                      streaming: streaming,
                      showReasoning: showReasoning,
                    ),
                    _buildProcessCollapseBar(theme, key),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessCollapseBar(ThemeData theme, String key) {
    return InkWell(
      onTap: () => _toggleProcessSection(key),
      child: Container(
        width: double.infinity,
        height: 28,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.chevron_up,
              size: 13,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 3),
            Text(
              '收起',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessSectionBody(
    ThemeData theme,
    ChatMessage message,
    ChatProcessSection section, {
    required bool streaming,
    required bool showReasoning,
  }) {
    final steps = section.visibleSteps(showReasoning: showReasoning);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _buildProcessStep(theme, message, steps[i], streaming: streaming),
          ],
        ],
      ),
    );
  }

  Widget _buildProcessStep(
    ThemeData theme,
    ChatMessage message,
    ChatPartRef ref, {
    required bool streaming,
  }) {
    final part = ref.part;
    return switch (part.type) {
      ChatMessagePartType.reasoning => _buildReasoningProcessStep(theme, part),
      ChatMessagePartType.tool => _buildToolProcessStep(
        theme,
        message,
        ref,
        streaming: streaming,
      ),
      ChatMessagePartType.text ||
      ChatMessagePartType.image => const SizedBox.shrink(),
    };
  }

  Widget _buildReasoningProcessStep(ThemeData theme, ChatMessagePart part) {
    final text = part.text.trim();
    final active = part.status == 'streaming' || part.status == 'running';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              LucideIcons.brain,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Text(
              active ? '还在想' : '想过',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.55,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.9),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildToolProcessStep(
    ThemeData theme,
    ChatMessage message,
    ChatPartRef ref, {
    required bool streaming,
  }) {
    final part = ref.part;
    final key = _toolKey(message, ref.index, part);
    final expanded = _expandedTools.contains(key);
    final running =
        streaming && (part.status == 'running' || part.status == 'streaming');
    final title = _toolPartTitle(part, running: running);
    final statusIcon = part.status == 'failed'
        ? LucideIcons.circle_alert
        : running
        ? LucideIcons.wrench
        : LucideIcons.check;
    return _ReportLayoutExtent(
      onLayout: (extent) {
        _toolStepExtents[key] = extent;
        _scroll.reportAnchorExtent(key, extent);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggleToolExpanded(key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    statusIcon,
                    size: 13,
                    color: part.status == 'failed'
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    expanded
                        ? LucideIcons.chevron_up
                        : LucideIcons.chevron_down,
                    size: 13,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _buildToolPartBody(theme, part),
            ),
        ],
      ),
    );
  }

  Widget _buildToolPartBody(ThemeData theme, ChatMessagePart part) {
    final tools = part.tools;
    if (tools.isEmpty) {
      final fallbackLabel = switch (part.status) {
        'done' => '处理好了',
        'failed' => '这一步没做完',
        _ => _toolRunningLabel,
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Text(
          fallbackLabel,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < tools.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _ToolCallView(
              tool: tools[i],
              displayName: _toolDisplayName(tools[i].name),
            ),
          ],
        ],
      ),
    );
  }

  /// v0.2.169：一条回复内部的时间线——思考轮次与工具状态按 round 穿插。
  /// 思路等价 RikkaHub ChatMessageCot.groupMessageParts：连续 Reasoning/Tool
  /// 步骤保持原始顺序分组渲染；Continuum Chat里 reasonings 按 round 存思考、
  /// toolDoneRounds 按 round 存完成标记，busy 占位嵌在当前执行轮之后，
  /// 渲染结果就是「思考1 → 在忙 → 搞定了 → 思考2 → 正文」。
  Widget _buildReplyTimeline(
    ChatMessage m, {
    required List<String> rounds,
    required Set<int> doneRounds,
    required bool streaming,
    required bool waitingContent,
    required bool inlineBusy,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: ReasoningPref.show,
      builder: (context, showReasoning, _) {
        final steps = <Widget>[];
        if (showReasoning && rounds.isEmpty && waitingContent && !inlineBusy) {
          // 思考刚开始还没吐出内容：一个占位卡片（收起态「我在想…」+ 呼吸省略号）
          steps.add(
            _buildThinkingCard(m, round: 1, text: _thinkingShown, active: true),
          );
        } else {
          final maxRound = math.max(
            rounds.length,
            math.max(
              doneRounds.isEmpty ? 0 : doneRounds.reduce(math.max),
              inlineBusy ? _busyRound : 0,
            ),
          );
          for (var r = 1; r <= maxRound; r++) {
            if (showReasoning && r <= rounds.length) {
              final text = rounds[r - 1];
              // 当前正在思考的轮（最新一轮）active：收起态「我在想…」+ 呼吸灯，
              // 展开态实时显示 _thinkingShown；历史轮次静态显示该轮完整内容
              final isCurrentRound = streaming && r == rounds.length;
              if (text.isNotEmpty || isCurrentRound) {
                steps.add(
                  _buildThinkingCard(
                    m,
                    round: r,
                    text: isCurrentRound ? _thinkingShown : text,
                    active: isCurrentRound,
                  ),
                );
              }
            }
            if (doneRounds.contains(r)) {
              steps.add(_buildToolStatusCard(ChatMessage.toolDoneLabel));
            }
            if (inlineBusy && _busyRound == r) {
              steps.add(_buildToolStatusCard(_busyLabel));
            }
          }
          // busy 轮次还没对上任何一轮思考（推理事件缺失等边缘）：贴时间线末尾
          if (inlineBusy && _busyRound > maxRound) {
            steps.add(_buildToolStatusCard(_busyLabel));
          }
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              steps[i],
            ],
          ],
        );
      },
    );
  }

  /// busy 占位文案（v0.2.118/153）：手机上执行换文案，round >= 2 带轮次数字。
  String get _busyLabel => chatBusyLabel(deviceRunning: _termuxRunning);

  /// 一轮思考气泡（与正文气泡同左缘，_kThinkingInset 缩进）；
  /// 展开/收起与整条复制沿用 v0.2.117/121 的行为。
  Widget _buildThinkingCard(
    ChatMessage m, {
    required int round,
    required String text,
    required bool active,
  }) {
    // v0.2.183：设置页开关关掉后完全不渲染思考气泡（只影响显示层）。
    return ValueListenableBuilder<bool>(
      valueListenable: ReasoningPref.show,
      builder: (context, showReasoning, _) {
        if (!showReasoning) return const SizedBox.shrink();
        final key = _thinkingKey(m, round);
        return Padding(
          padding: const EdgeInsets.only(left: _kThinkingInset),
          child: _ReportLayoutExtent(
            onLayout: (extent) {
              _thinkingCardExtents[key] = extent;
              _scroll.reportAnchorExtent(key, extent);
            },
            child: ThinkingCard(
              key: ValueKey<String>('thinking:$key'),
              headerAnchorKey: _thinkingAnchorKeys.putIfAbsent(
                key,
                () => GlobalKey(debugLabel: 'thinking-header:$key'),
              ),
              active: active,
              text: text,
              expanded: _expandedThinking.contains(key),
              onToggle: () => _toggleThinkingExpanded(m, round),
              // v0.2.117：思考内容可复制整条（本轮）
              onCopyAll: () {
                Clipboard.setData(ClipboardData(text: text));
                _showToast(text.isEmpty ? '没有内容' : '已复制');
              },
            ),
          ),
        );
      },
    );
  }

  /// 时间线里的工具状态块（在忙…/✓ 搞定了）：样式沿用 busyCard 低调小胶囊，
  /// 与思考气泡同左缘对齐（v0.2.169 从列表居中占位改为回复内部左对齐块）。
  Widget _buildToolStatusCard(String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: _kThinkingInset),
      child: MessageBubble.busyCard(
        theme,
        label: chatToolDoneDisplayLabel(label),
        alignment: Alignment.centerLeft,
      ),
    );
  }

  // 标题下方的小字行：正在输入中 + 三个跳动点
  Widget _buildTypingRow(ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '正在输入中',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: 5),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // 三个点相位错开 400ms（1200ms / 3），依次跳动
            final phase = (_typingAnim.value - i / 3) % 1.0;
            final opacity =
                0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
            return Opacity(
              opacity: opacity,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  width: 3,
                  height: 3,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _ToolCallView extends StatelessWidget {
  final ChatToolCallPart tool;
  final String displayName;

  const _ToolCallView({required this.tool, required this.displayName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final args = _formatArgs(tool.arguments);
    final result = _formatResult(tool.result);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                displayName.isEmpty ? '处理' : displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              _statusLabel(tool.status),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: tool.status == 'failed'
                    ? theme.colorScheme.error.withValues(alpha: 0.86)
                    : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ToolPayloadBlock(label: '输入', text: args, monospace: true),
        if (result.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ToolPayloadBlock(label: '结果', text: result),
        ],
      ],
    );
  }

  static String _statusLabel(String status) {
    return switch (status) {
      'running' || 'streaming' => '处理中',
      'failed' => '没完成',
      _ => '完成',
    };
  }

  static String _formatArgs(Map<String, dynamic> args) {
    try {
      return const JsonEncoder.withIndent('  ').convert(args);
    } catch (_) {
      return args.toString();
    }
  }

  static String _formatResult(String raw) {
    var text = raw.trim();
    for (final prefix in const ['[工具结果]：', '[工具结果]:']) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trimLeft();
        break;
      }
    }
    if (text.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }
}

class _ToolPayloadBlock extends StatelessWidget {
  final String label;
  final String text;
  final bool monospace;

  const _ToolPayloadBlock({
    required this.label,
    required this.text,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = context.fieldColor;
    final contentColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.9,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 9),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: '复制$label',
                child: IconButton(
                  tooltip: '复制$label',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 15,
                  color: theme.colorScheme.outline,
                  icon: const Icon(LucideIcons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    messenger?.hideCurrentSnackBar();
                    messenger?.showSnackBar(
                      SnackBar(
                        content: Text('已复制$label'),
                        duration: const Duration(milliseconds: 900),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            text,
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: contentColor,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatScrollController extends ScrollController {
  _ViewportAnchorRequest? _anchorRequest;

  void preserveAnchorOnNextLayout(String anchorId, double oldExtent) {
    final current = _anchorRequest;
    if (current?.anchorId == anchorId) return;
    if (!hasClients) return;
    _anchorRequest = _ViewportAnchorRequest(
      anchorId: anchorId,
      oldExtent: oldExtent,
      oldPixels: position.pixels,
    );
  }

  void reportAnchorExtent(String anchorId, double extent) {
    final request = _anchorRequest;
    if (request?.anchorId == anchorId) request!.newExtent = extent;
  }

  void _clearAnchorRequest(_ViewportAnchorRequest request) {
    if (identical(_anchorRequest, request)) _anchorRequest = null;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ChatScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      owner: this,
    );
  }
}

class _ChatScrollPosition extends ScrollPositionWithSingleContext {
  _ChatScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    required super.oldPosition,
    required super.debugLabel,
    required this.owner,
  });

  final _ChatScrollController owner;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final request = owner._anchorRequest;
    if (request != null) {
      final newExtent = request.newExtent;
      if (newExtent != null && axisDirectionIsReversed(axisDirection)) {
        final extentDelta = newExtent - request.oldExtent;
        if (extentDelta.abs() > 0.5) {
          final corrected = (request.oldPixels + extentDelta)
              .clamp(minScrollExtent, maxScrollExtent)
              .toDouble();
          owner._clearAnchorRequest(request);
          if ((corrected - pixels).abs() > 0.5) {
            correctPixels(corrected);
            return false;
          }
        }
      }
      owner._clearAnchorRequest(request);
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

class _ViewportAnchorRequest {
  _ViewportAnchorRequest({
    required this.anchorId,
    required this.oldExtent,
    required this.oldPixels,
  });

  final String anchorId;
  final double oldExtent;
  final double oldPixels;
  double? newExtent;
}

class _AskOptionButton extends StatefulWidget {
  final String label;
  final bool selected;
  final bool locked;
  final bool loading;
  final VoidCallback? onTap;

  const _AskOptionButton({
    required this.label,
    required this.selected,
    required this.locked,
    required this.loading,
    required this.onTap,
  });

  @override
  State<_AskOptionButton> createState() => _AskOptionButtonState();
}

class _AskOptionButtonState extends State<_AskOptionButton> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null && !widget.locked;

  void _setPressed(bool value) {
    if (!_enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(covariant _AskOptionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final muted = widget.locked && !widget.selected;
    final baseBg = context.fieldColor;
    final selectedBg = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: dark ? 0.12 : 0.08),
      baseBg,
    );
    final pressedBg = Color.alphaBlend(
      theme.colorScheme.onSurface.withValues(alpha: dark ? 0.08 : 0.05),
      widget.selected ? selectedBg : baseBg,
    );
    final textColor = widget.selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: _enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedOpacity(
          opacity: muted ? 0.52 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: _pressed
                  ? pressedBg
                  : (widget.selected ? selectedBg : baseBg),
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: widget.selected ? [context.cardShadow] : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 22,
                  child: AnimatedOpacity(
                    opacity: widget.selected ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    child: widget.loading
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: theme.colorScheme.primary,
                            ),
                          )
                        : Icon(
                            LucideIcons.check,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.label,
                    softWrap: true,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 待发/上传中的单张图：原始字节 + 文件名（多选发图批量单元）。
class _PendingImageItem {
  final Uint8List bytes;
  final String name;

  _PendingImageItem(this.bytes, this.name);
}

/// 多选发图批次（占位气泡重试用）：全部待发图 + 附带文字；
/// urls/ocrs 与 items 下标一一对应，空串 = 该张还没成功（重试只补传这些）。
class _PendingImageData {
  final List<_PendingImageItem> items;
  final String text;
  final List<String> urls;
  final List<String> ocrs;

  _PendingImageData(this.items, this.text)
    : urls = List<String>.filled(items.length, ''),
      ocrs = List<String>.filled(items.length, '');
}

/// 待发文件（占位卡片重试用）：本地缓存路径 + 文件名/大小/类型 + 配字。
class _PendingFileData {
  final String path;
  final String name;
  final int size;
  final String type;
  final String text;

  _PendingFileData(this.path, this.name, this.size, this.type, this.text);
}

/// /files 上传响应：URL + 元信息 + 服务端自动提取文本（模型可见）。
class _FileUploadResult {
  final String url;
  final String name;
  final int size;
  final String type;
  final String text;

  _FileUploadResult({
    required this.url,
    required this.name,
    required this.size,
    required this.type,
    required this.text,
  });
}
