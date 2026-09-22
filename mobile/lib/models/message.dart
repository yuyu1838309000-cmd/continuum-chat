import 'dart:typed_data';

/// 图片发送状态（瞬态，不落盘）：
/// 点发送后消息流立即出现"发送中"占位气泡，上传+OCR 完成后原地替换成
/// 真实图片消息；失败时保持"发送失败"，可点击重试或删除。
enum ImageSendStatus { sending, failed }

/// 文件发送状态（瞬态，不落盘）：加号按钮选文件 → 占位文件卡片 →
/// 上传+内容提取完成后原地升级成真实文件消息；失败可重试/删除。
enum FileSendStatus { sending, failed }

/// 一条 assistant 消息内部的时间线部件。
/// 服务端会把不同模型的思考/正文/工具/图片统一归一化成这个序列；
/// 旧 content/reasoning/reasonings/toolDoneRounds 字段仍保留，用于历史消息兜底。
enum ChatMessagePartType { text, reasoning, tool, image }

ChatMessagePartType _partTypeFromString(String raw) {
  return switch (raw) {
    'reasoning' => ChatMessagePartType.reasoning,
    'tool' => ChatMessagePartType.tool,
    'image' => ChatMessagePartType.image,
    _ => ChatMessagePartType.text,
  };
}

String _partTypeToString(ChatMessagePartType type) {
  return switch (type) {
    ChatMessagePartType.text => 'text',
    ChatMessagePartType.reasoning => 'reasoning',
    ChatMessagePartType.tool => 'tool',
    ChatMessagePartType.image => 'image',
  };
}

class ChatToolCallPart {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String status;
  final String result;

  const ChatToolCallPart({
    this.id = '',
    this.name = '',
    this.arguments = const {},
    this.status = 'done',
    this.result = '',
  });

  factory ChatToolCallPart.fromJson(Map<String, dynamic> j) {
    final rawArgs = j['arguments'];
    return ChatToolCallPart(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      arguments: rawArgs is Map
          ? rawArgs.map((k, v) => MapEntry(k.toString(), v))
          : const {},
      status: j['status']?.toString() ?? 'done',
      result: j['result']?.toString() ?? '',
    );
  }

  ChatToolCallPart copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? arguments,
    String? status,
    String? result,
  }) {
    return ChatToolCallPart(
      id: id ?? this.id,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
      status: status ?? this.status,
      result: result ?? this.result,
    );
  }

  Map<String, dynamic> toJson() => {
    if (id.isNotEmpty) 'id': id,
    'name': name,
    if (arguments.isNotEmpty) 'arguments': arguments,
    if (status.isNotEmpty) 'status': status,
    if (result.isNotEmpty) 'result': result,
  };
}

class ChatMessagePart {
  final ChatMessagePartType type;
  String text;
  final String delta;
  final int round;
  String status;
  final String url;
  List<ChatToolCallPart> tools;

  ChatMessagePart({
    required this.type,
    this.text = '',
    this.delta = '',
    this.round = 0,
    this.status = 'done',
    this.url = '',
    this.tools = const [],
  });

  factory ChatMessagePart.fromJson(Map<String, dynamic> j) {
    final rawTools = j['tools'];
    return ChatMessagePart(
      type: _partTypeFromString(j['type']?.toString() ?? 'text'),
      text: (j['text'] ?? j['content'] ?? j['delta'] ?? '').toString(),
      delta: j['delta']?.toString() ?? '',
      round: (j['round'] as num?)?.toInt() ?? 0,
      status: j['status']?.toString() ?? 'done',
      url: j['url']?.toString() ?? '',
      tools: rawTools is List
          ? [
              for (final item in rawTools)
                if (item is Map)
                  ChatToolCallPart.fromJson(
                    item.map((k, v) => MapEntry(k.toString(), v)),
                  ),
            ]
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'type': _partTypeToString(type),
    if (text.isNotEmpty) 'text': text,
    if (round > 0) 'round': round,
    if (status.isNotEmpty) 'status': status,
    if (url.isNotEmpty) 'url': url,
    if (tools.isNotEmpty) 'tools': tools.map((e) => e.toJson()).toList(),
  };
}

/// 网页搜索到的网站（v0.2.117）：搜索完成后存进消息对象（标题+URL），
/// 点开搜索气泡显示；随消息持久化落盘。
class SearchResult {
  final String title;
  final String url;

  const SearchResult({required this.title, required this.url});

  Map<String, String> toJson() => {'title': title, 'url': url};

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
  );
}

/// 聊天消息模型。
/// role: user / assistant / activity（AI 助手静默期干的活的展示卡片，纯展示不注入模型）
/// / tool_done（AI 助手工具执行完成的"✓ 搞定了！"固定记录，纯展示不注入模型）；
/// content 可变（流式填充）；time 创建时间。
/// rawEventId：服务器 raw_events 里的记录 id（8816 /chat 结束 metadata 回填）。
/// 用于精确删除：归档删除时按 id 列表软删服务器记录，不按时间范围粗删；
/// id 为 null 时删除走本地兜底（只删本地存档）。
class ChatMessage {
  final String role; // user / assistant / activity
  String content;

  /// activity / tool_done 纯展示消息：渲染成对话流居中低调小卡片，
  /// 不参与发送给 DeepSeek 的消息列表（ChatApi 按此过滤），也不写 raw_events。
  /// activity = 静默活动动态卡片；tool_done = 工具执行完成标记。
  /// tool_done 复用这条过滤管线，零改动 ChatApi/ChatStore 即不注入模型、自动落盘。
  bool get isActivity => role == 'activity' || role == 'tool_done';

  /// AI 助手工具执行完成标记（v0.2.168）：busy 占位执行完变成
  /// "✓ 搞定了！"，作为固定消息记录永久保留在对话流（落盘，重启后仍在）。
  /// 样式同 MessageBubble.busyCard，纯展示。
  bool get isToolDone => role == 'tool_done';

  /// "✓ 搞定了！"完成标记文案（渲染与 content 共用，禁止散落硬编码）。
  static const String toolDoneLabel = '✓ 搞定了！';

  /// 思考内容（deepseek-v4-flash 的 reasoning_content，流式填充）。
  /// 默认收起，点回复旁的 🧠 图标展开看。旧消息/没思考的为空。
  String reasoning;

  /// v0.2.121：多轮思考按轮存储（index = round-1，模型每用一次工具后
  /// 独立思考一轮）。渲染时每轮一个思考气泡；单字段 reasoning 保留用于
  /// 落盘全量/导出。老消息只有 reasoning 没有本列表（按单轮显示）。
  List<String> reasonings;

  /// 工具完成轮次（v0.2.169，index 即 round-1）：每轮工具执行完追加一条，
  /// 渲染时与 reasonings 按轮次穿插（思考1 → ✓ 搞定了 → 思考2 → 正文），
  /// 不再作为独立 tool_done 消息堆在回复前。随消息落盘，重启后仍在；
  /// 老消息没有本字段（空列表），历史 tool_done 独立消息仍按原样式渲染。
  List<int> toolDoneRounds;

  final DateTime time;

  /// 服务器 raw_events 记录 id（软删用）。旧消息/没存过的为 null。
  int? rawEventId;

  /// Agent Runtime canonical event id。旧本地历史可能为空；为空时不能伪造
  /// server mutation 成功。
  String? eventId;

  /// 本地稳定 client identity。发送 retry / 页面重建时复用，不进入正文。
  String? clientEventId;

  /// 生成归属 id，用于 active generation resume/cancel 与消息 cache linking。
  String? generationId;

  /// ContextEpoch id，canonical mutation route 需要。旧本地历史为空。
  String? epochId;

  /// 内部消息种类，保留给 Runtime/cache 迁移使用，不参与可见正文。
  String? kind;

  /// 最后应用到该消息的 runtime seq，便于本地 cache 去重。
  int? runtimeSeq;

  /// 消息关联 generation 的最后已知状态。
  String? runtimeStatus;

  /// 图片消息：服务器 URL（12④ 图片消息）。空 = 纯文本。
  /// 可以是纯图片（content 空）/ 文字+图（content 有文字）。
  String? imageUrl;

  /// OCR 识别结果（图片内容文字，仅模型可见）。
  /// 气泡渲染不显示它（用户只看图片 + 自己输入的文字）；
  /// ChatApi.send 构造请求时把 [我发了一张图：URL] 图片内容：OCR结果 拼进 content 给模型"看到"。
  String? ocrText;

  /// 多选发图（一次 N 张）：每张的服务器 URL 与 OCR 文本，按下标一一对应。
  /// 有值时气泡竖向渲染多张图；ChatApi.send 把"发了 N 张图 + 合并 OCR"拼进
  /// content，模型一次看到全部图，只回一条。
  List<String> imageUrls;
  List<String> imageOcrTexts;

  /// 文件消息：服务器 URL、文件名、文件大小（字节）。有 fileUrl 时气泡渲染成
  /// 文件卡片（图标 + 文件名 + 大小 + 点开下载），不把裸 URL 当正文显示。
  String? fileUrl;
  String? fileName;
  int? fileSize;

  /// 文件类型（image/audio/doc）：决定文件卡片图标。
  String? fileType;

  /// 服务器内容提取文本（文档解析/原图 OCR/音频 ASR，仅模型可见）。
  /// ChatApi.send 构造请求时拼进 content；气泡不显示。
  String? fileExtractedText;

  /// 网页搜索中：旧 [search] 标记链路的历史遗留字段（服务端已改为
  /// 原生 search 工具，结果直接进正文）。保留字段只为老消息渲染兼容，
  /// 新消息不再写。瞬态状态不持久化，重启恢复 false。
  bool searching;

  /// 网页搜索完成标记（v0.2.117）：搜索结束后气泡不消失，
  /// 改为"搜索完成了！"保留在对话流里（没搜到则显示"搜索没完成"）。
  /// 持久化落盘，重启后仍在。
  bool searchDone;

  /// 搜到的网站列表（Tavily url/title，v0.2.117）：点开搜索气泡显示
  /// （标题+URL 简单列表）。持久化落盘。
  List<SearchResult> searchResults;

  /// 图片发送中/发送失败占位状态（瞬态，不落盘）：
  /// sending = 上传+OCR 中，气泡显示缩略图+加载；failed = 上传失败可重试。
  /// 发送成功后置回 null（同一消息对象原地升级成真实图片消息，不跳位）。
  ImageSendStatus? imageSendStatus;

  /// 占位气泡用的本地图片字节（瞬态，不落盘）。
  /// 图片上传成功后清空，改走 imageUrl 渲染。
  Uint8List? imagePreviewBytes;

  /// 多选发图占位（瞬态，不落盘）：全部待发图的本地字节，按选中顺序排列。
  List<Uint8List> imagePreviewBytesList;

  /// 多选发图逐张状态（瞬态，不落盘）：0=上传中 / 1=成功 / 2=失败，
  /// 与 imagePreviewBytesList 下标一一对应；全部 1 后整条消息原地升级发送。
  List<int> imageItemStates;

  /// 文件发送中/失败占位（瞬态，不落盘）：发送中显示加载，失败可重试。
  FileSendStatus? fileSendStatus;

  /// 服务端归一化后的消息内部部件序列：思考/正文/工具/图片按真实时间顺序排列。
  List<ChatMessagePart> parts;

  /// 文本消息发送失败（请求未成功发起/上游未开始返回）：用户消息前显示感叹号，
  /// 点击后把内容放回输入框，用户手动编辑后再发送。
  bool sendFailed;
  String? sendError;

  ChatMessage({
    required this.role,
    required this.content,
    this.reasoning = '',
    this.reasonings = const [],
    this.toolDoneRounds = const [],
    DateTime? time,
    this.rawEventId,
    this.eventId,
    this.clientEventId,
    this.generationId,
    this.epochId,
    this.kind,
    this.runtimeSeq,
    this.runtimeStatus,
    this.imageUrl,
    this.ocrText,
    this.imageUrls = const [],
    this.imageOcrTexts = const [],
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.fileType,
    this.fileExtractedText,
    this.searching = false,
    this.searchDone = false,
    this.searchResults = const [],
    this.imageSendStatus,
    this.imagePreviewBytes,
    this.imagePreviewBytesList = const [],
    this.imageItemStates = const [],
    this.fileSendStatus,
    this.parts = const [],
    this.sendFailed = false,
    this.sendError,
    this.usage,
  }) : time = time ?? DateTime.now();

  Map<String, dynamic> toApi() => {
    'role': role,
    'content': content,
    if (rawEventId != null) 'raw_event_id': rawEventId,
  };

  /// token 用量（assistant 消息，流式末尾 usage 事件解析，命中率显示用）
  MessageUsage? usage;
}

/// token 用量统计（DeepSeek 流式末尾 usage 事件）。
/// hitRate：缓存命中率 = cacheHit / (cacheHit + cacheMiss)。
class MessageUsage {
  final int promptTokens;
  final int cacheHit;
  final int cacheMiss;
  final int completionTokens;

  const MessageUsage({
    required this.promptTokens,
    required this.cacheHit,
    required this.cacheMiss,
    required this.completionTokens,
  });

  /// 缓存命中率（0-1）。cacheHit + cacheMiss 为 0 时按 0 处理。
  double get hitRate {
    final total = cacheHit + cacheMiss;
    return total == 0 ? 0 : cacheHit / total;
  }

  factory MessageUsage.fromJson(Map<String, dynamic> j) {
    final rawTotals = j['totals'];
    final source = rawTotals is Map
        ? rawTotals.map((key, value) => MapEntry(key.toString(), value))
        : j;

    int readInt(List<String> keys) {
      for (final key in keys) {
        final value = source[key];
        if (value is num) return value.toInt();
        final parsed = int.tryParse(value?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      return 0;
    }

    return MessageUsage(
      promptTokens: readInt(const ['prompt_tokens', 'input_tokens']),
      cacheHit: readInt(const [
        'prompt_cache_hit_tokens',
        'cache_read_input_tokens',
      ]),
      cacheMiss: readInt(const [
        'prompt_cache_miss_tokens',
        'cache_creation_input_tokens',
      ]),
      completionTokens: readInt(const ['completion_tokens', 'output_tokens']),
    );
  }

  Map<String, dynamic> toJson() => {
    'prompt_tokens': promptTokens,
    'prompt_cache_hit_tokens': cacheHit,
    'prompt_cache_miss_tokens': cacheMiss,
    'completion_tokens': completionTokens,
  };
}
