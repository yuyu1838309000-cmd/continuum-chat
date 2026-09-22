import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/assistant_channel_page.dart';
import 'package:continuum_chat/services/assistant_channel_api.dart';
import 'package:continuum_chat/utils/app_theme.dart';

const _session = AssistantChannelSession(
  sessionId: '20260912-collaboration-01',
  messageCount: 2,
  createdAt: '2026-09-12T13:00:00Z',
  firstMessageAt: '2026-09-12T13:00:00Z',
  lastMessageAt: '2026-09-12T13:01:00Z',
);

const _messages = [
  AssistantChannelMessage(
    id: 1,
    sessionId: '20260912-collaboration-01',
    role: 'chatgpt',
    speaker: 'chatgpt',
    content: '这是 ChatGPT 发来的完整原文。',
    createdAt: '2026-09-12T13:00:00Z',
  ),
  AssistantChannelMessage(
    id: 2,
    sessionId: '20260912-collaboration-01',
    role: 'assistant',
    speaker: 'assistant',
    content: '这是AI 助手回复的完整原文，没有省略。',
    createdAt: '2026-09-12T13:01:00Z',
  ),
];

const _audit = AssistantChannelAuditSnapshot(
  bridges: [
    AssistantChannelBridge(
      versionId: 9,
      previousVersionId: 8,
      memoryId: 'bridge-1',
      topic: '最近留档',
      summary: 'Bridge 摘要',
      detail: 'Bridge 完整内容',
      status: 'unresolved',
      revisionAction: 'revise',
      createdAt: '2026-09-12T13:02:00Z',
      sourceRefs: [
        AssistantChannelSourceRef(
          sessionId: '20260912-collaboration-01',
          messageId: 2,
          role: 'assistant',
          createdAt: '2026-09-12T13:01:00Z',
        ),
      ],
    ),
  ],
  notes: [
    {'id': 3, 'title': '一条 note', 'content': 'AI 助手 note 原文'},
  ],
  toolEvents: [
    {'id': 4, 'tool': 'memory_recall', 'actor': 'assistant'},
  ],
  traces: [
    AssistantChannelTrace(
      id: 5,
      traceType: 'runtime_auto_recall',
      surface: 'contact',
      memoryId: 'bridge-1',
      versionId: 9,
      matchReason: 'priority=95',
      createdAt: '2026-09-12T13:03:00Z',
      sourceRefs: [],
    ),
  ],
  status: AssistantChannelStatus(
    quickCheck: 'ok',
    counts: {'sessions': 1, 'messages': 2, 'bridges': 1},
    lastBackupAt: '2026-09-12T13:04:00Z',
  ),
);

class _FakeReader implements AssistantChannelReader {
  _FakeReader({this.sessions = const [_session], this.sessionsError});

  final List<AssistantChannelSession> sessions;
  final Object? sessionsError;
  int auditLoads = 0;

  @override
  Future<AssistantChannelAuditSnapshot> fetchAudit() async {
    auditLoads += 1;
    return _audit;
  }

  @override
  Future<List<AssistantChannelMessage>> fetchHistory(String sessionId) async {
    expect(sessionId, _session.sessionId);
    return _messages;
  }

  @override
  Future<List<AssistantChannelSession>> fetchSessions() async {
    if (sessionsError != null) throw sessionsError!;
    return sessions;
  }
}

void main() {
  testWidgets('starts with sessions and opens complete read-only transcript', (
    tester,
  ) async {
    final reader = _FakeReader();
    await tester.pumpWidget(
      MaterialApp(home: AssistantChannelPage(reader: reader)),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 协作记录'), findsWidgets);
    expect(find.text('只读存档，不会向这条通道发送消息'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('assistant_channel_sessions')),
      findsOneWidget,
    );
    expect(find.textContaining(_session.sessionId), findsOneWidget);
    expect(reader.auditLoads, 0);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.textContaining(_session.sessionId));
    await tester.pumpAndSettle();

    expect(find.text('AI 协作记录'), findsOneWidget);
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('AI 助手'), findsOneWidget);
    expect(find.text(_messages.first.content), findsOneWidget);
    expect(find.text(_messages.last.content), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .every((widget) => widget.readOnly),
      isTrue,
    );
  });

  testWidgets('audit exposes versions, refs and distinct recall sources', (
    tester,
  ) async {
    final reader = _FakeReader();
    await tester.pumpWidget(
      MaterialApp(home: AssistantChannelPage(reader: reader)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('assistant_channel_audit_tab')));
    await tester.pumpAndSettle();

    expect(reader.auditLoads, 1);
    expect(find.text('存档状态正常'), findsOneWidget);
    expect(find.text('Bridge 当前版'), findsOneWidget);
    expect(find.text('当前版本 #9'), findsOneWidget);
    expect(find.text('上一版 #8'), findsOneWidget);
    expect(find.text('Source refs'), findsOneWidget);
    final auditScroll = find
        .descendant(
          of: find.byKey(const ValueKey('assistant_channel_audit')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('AI 助手 notes'),
      260,
      scrollable: auditScroll,
    );
    expect(find.text('AI 助手 notes'), findsOneWidget);
    expect(find.textContaining('AI 助手 note 原文'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Tool events'),
      260,
      scrollable: auditScroll,
    );
    expect(find.text('Tool events'), findsOneWidget);
    expect(find.text('AI 助手主动翻档'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Injection traces'),
      260,
      scrollable: auditScroll,
    );
    expect(find.text('Injection traces'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('系统自动提醒').first,
      260,
      scrollable: auditScroll,
    );
    expect(find.text('系统自动提醒'), findsWidgets);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('empty and error states are explicit', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantChannelPage(reader: _FakeReader(sessions: const [])),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有保存的 AI 协作记录'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: AssistantChannelPage(
          key: const ValueKey('failed-reader'),
          reader: _FakeReader(sessionsError: StateError('offline')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取 AI 协作记录'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('sessions, audit and transcript fit compact phone widths', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 700));
      for (final theme in [appTheme.light, appTheme.dark]) {
        final reader = _FakeReader();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            home: AssistantChannelPage(reader: reader),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(
          find.byKey(const ValueKey('assistant_channel_audit_tab')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            home: AssistantChannelSessionPage(
              session: _session,
              reader: reader,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  });
}
