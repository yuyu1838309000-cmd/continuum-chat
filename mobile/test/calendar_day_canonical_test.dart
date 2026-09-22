import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/calendar_page.dart';
import 'package:continuum_chat/pages/day_page.dart';
import 'package:continuum_chat/pages/read_only_chat_view_page.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_models.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef _CalendarHandler =
    Future<HistoryCalendarSnapshot> Function(
      DateTime start,
      DateTime end,
      int timezoneOffsetMinutes,
    );

typedef _DayHandler =
    Future<HistoryDaySnapshot> Function(DateTime start, DateTime end);

typedef _UsageHandler =
    Future<HistoryTokenUsageSnapshot> Function(
      DateTime start,
      DateTime end,
      int timezoneOffsetMinutes,
    );

typedef _ConversationsHandler =
    Future<HistoryConversationPage> Function(
      int? beforeOrdinal,
      int limit,
      int? expectedRevision,
    );

class _FakeHistoryRepository extends RuntimeHistoryRepository {
  _FakeHistoryRepository({
    this.calendarHandler,
    this.dayHandler,
    this.usageHandler,
    this.conversationsHandler,
  }) : super(
         api: RuntimeHistoryApi(
           client: MockClient((_) async => http.Response('{"ok":false}', 500)),
         ),
       );

  final _CalendarHandler? calendarHandler;
  final _DayHandler? dayHandler;
  final _UsageHandler? usageHandler;
  final _ConversationsHandler? conversationsHandler;

  @override
  Future<HistoryConversationPage> conversations({
    int? beforeOrdinal,
    int limit = 50,
    int? expectedRevision,
  }) =>
      conversationsHandler?.call(beforeOrdinal, limit, expectedRevision) ??
      Future.value(
        const HistoryConversationPage(
          items: [],
          fromCache: false,
          hasMore: false,
        ),
      );

  @override
  Future<HistoryCalendarSnapshot> calendar({
    required DateTime start,
    required DateTime end,
    required int timezoneOffsetMinutes,
    int? expectedRevision,
  }) => calendarHandler!(start, end, timezoneOffsetMinutes);

  @override
  Future<HistoryDaySnapshot> completeDayMessages({
    required DateTime start,
    required DateTime end,
    int pageSize = 200,
  }) => dayHandler!(start, end);

  @override
  Future<HistoryTokenUsageSnapshot> tokenUsage({
    required DateTime start,
    required DateTime end,
    required int timezoneOffsetMinutes,
    int pageSize = 200,
  }) =>
      usageHandler?.call(start, end, timezoneOffsetMinutes) ??
      Future.value(const HistoryTokenUsageSnapshot(days: [], fromCache: false));
}

void main() {
  testWidgets(
    'calendar sends exact UTC+8 local-month range and marks messages',
    (tester) async {
      late DateTime capturedStart;
      late DateTime capturedEnd;
      late int capturedOffset;
      final repository = _FakeHistoryRepository(
        calendarHandler: (start, end, offset) async {
          capturedStart = start;
          capturedEnd = end;
          capturedOffset = offset;
          return const HistoryCalendarSnapshot(
            days: [HistoryCalendarDay(date: '2026-09-05', messageCount: 2)],
            fromCache: true,
            revision: 9,
          );
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CalendarPage(
            repository: repository,
            initialMonth: DateTime(2026, 9),
            timezoneOffsetMinutes: 480,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(capturedStart, DateTime.parse('2026-08-31T16:00:00Z'));
      expect(capturedEnd, DateTime.parse('2026-09-30T16:00:00Z'));
      expect(capturedOffset, 480);
      expect(find.text('离线缓存'), findsOneWidget);
      expect(find.text('有消息但缺 usage'), findsOneWidget);
      expect(find.text('有对话'), findsNothing);
      expect(find.text('有归档'), findsNothing);
      expect(_dotColor(tester, '2026-09-05'), isNot(Colors.transparent));
    },
  );

  testWidgets('late old-month response cannot overwrite the new month', (
    tester,
  ) async {
    final september = Completer<HistoryCalendarSnapshot>();
    final october = Completer<HistoryCalendarSnapshot>();
    final repository = _FakeHistoryRepository(
      calendarHandler: (start, _, _) =>
          start == DateTime.parse('2026-08-31T16:00:00Z')
          ? september.future
          : october.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarPage(
          repository: repository,
          initialMonth: DateTime(2026, 9),
          timezoneOffsetMinutes: 480,
        ),
      ),
    );

    await tester.tap(find.byTooltip('下一月'));
    await tester.pump();
    october.complete(
      const HistoryCalendarSnapshot(
        days: [HistoryCalendarDay(date: '2026-10-02', messageCount: 1)],
        fromCache: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年10月'), findsOneWidget);
    expect(_dotColor(tester, '2026-10-02'), isNot(Colors.transparent));

    september.complete(
      const HistoryCalendarSnapshot(
        days: [HistoryCalendarDay(date: '2026-09-03', messageCount: 1)],
        fromCache: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年10月'), findsOneWidget);
    expect(_dotColor(tester, '2026-10-02'), isNot(Colors.transparent));
  });

  testWidgets(
    'calendar keeps month, recent, daily and lazy all ranges independent',
    (tester) async {
      final usageCalls = <(DateTime, DateTime, int)>[];
      var conversationCalls = 0;
      final repository = _FakeHistoryRepository(
        calendarHandler: (_, _, _) async => const HistoryCalendarSnapshot(
          days: [HistoryCalendarDay(date: '2026-09-19', messageCount: 2)],
          fromCache: false,
        ),
        usageHandler: (start, end, offset) async {
          usageCalls.add((start, end, offset));
          if (start == DateTime.parse('2026-08-31T16:00:00Z')) {
            return const HistoryTokenUsageSnapshot(
              days: [
                HistoryTokenUsageDay(
                  date: '2026-09-19',
                  inputTokens: 24680,
                  outputTokens: 6420,
                ),
              ],
              fromCache: false,
            );
          }
          if (start == DateTime.parse('2026-08-20T16:00:00Z')) {
            return const HistoryTokenUsageSnapshot(
              days: [
                HistoryTokenUsageDay(
                  date: '2026-08-21',
                  inputTokens: 1200,
                  outputTokens: 300,
                ),
              ],
              fromCache: false,
            );
          }
          return const HistoryTokenUsageSnapshot(
            days: [
              HistoryTokenUsageDay(
                date: '2026-07-02',
                inputTokens: 90000,
                outputTokens: 30000,
              ),
            ],
            fromCache: false,
          );
        },
        conversationsHandler: (_, _, _) async {
          conversationCalls += 1;
          return HistoryConversationPage(
            items: [
              HistoryConversationSummary(
                epochId: 'epoch-1',
                ordinal: 1,
                status: 'closed',
                messageCount: 2,
                openedAt: DateTime.parse('2026-07-01T16:00:00Z'),
              ),
            ],
            fromCache: false,
            hasMore: false,
            revision: 7,
          );
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CalendarPage(
            repository: repository,
            initialMonth: DateTime(2026, 9),
            usageAnchor: DateTime(2026, 9, 19, 12),
            timezoneOffsetMinutes: 480,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(usageCalls, hasLength(2));
      expect(conversationCalls, 0, reason: '全部 must remain lazy');
      expect(
        usageCalls,
        contains((
          DateTime.parse('2026-08-20T16:00:00Z'),
          DateTime.parse('2026-09-19T16:00:00Z'),
          480,
        )),
      );
      expect(
        usageCalls,
        contains((
          DateTime.parse('2026-08-31T16:00:00Z'),
          DateTime.parse('2026-09-30T16:00:00Z'),
          480,
        )),
      );
      expect(
        find.byKey(const ValueKey('usage-day-2026-08-21')),
        findsOneWidget,
      );
      expect(find.text('24,680'), findsOneWidget);
      expect(find.text('6,420'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('usage-view-monthly')),
      );
      await tester.tap(find.byKey(const ValueKey('usage-view-monthly')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-month-2026-09')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('usage-view-all')));
      await tester.pumpAndSettle();
      expect(conversationCalls, 1);
      expect(usageCalls, hasLength(3));
      expect(usageCalls.last, (
        DateTime.parse('2026-07-01T16:00:00Z'),
        DateTime.parse('2026-09-19T16:00:00Z'),
        480,
      ));
      expect(find.byKey(const ValueKey('usage-all')), findsOneWidget);
      expect(find.text('90,000'), findsOneWidget);
      expect(find.text('30,000'), findsOneWidget);
      expect(find.text('现有可统计历史'), findsOneWidget);
    },
  );

  testWidgets(
    '390 layout follows Figma structure and distinguishes missing usage',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      await binding.setSurfaceSize(const Size(390, 844));
      final repository = _FakeHistoryRepository(
        calendarHandler: (_, _, _) async => const HistoryCalendarSnapshot(
          days: [HistoryCalendarDay(date: '2026-09-05', messageCount: 1)],
          fromCache: false,
        ),
        usageHandler: (start, _, _) async => HistoryTokenUsageSnapshot(
          days: start == DateTime.parse('2026-08-31T16:00:00Z')
              ? const [
                  HistoryTokenUsageDay(
                    date: '2026-09-06',
                    inputTokens: 0,
                    outputTokens: 0,
                  ),
                ]
              : const [],
          fromCache: false,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CalendarPage(
            repository: repository,
            initialMonth: DateTime(2026, 9),
            usageAnchor: DateTime(2026, 9, 19, 12),
            timezoneOffsetMinutes: 480,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('日历'), findsOneWidget);
      expect(find.text('2026年9月'), findsOneWidget);
      expect(find.text('近30天 Token 热力'), findsOneWidget);
      expect(find.text('Provider 实际返回'), findsOneWidget);
      expect(find.text('当天'), findsOneWidget);
      expect(find.text('本月'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('点日期查看这一天聊了什么'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('9月5日.*有消息，无 Provider usage')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('9月6日.*0 Token，Provider 已返回')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('calendar HTTP error retries into a real empty month', (
    tester,
  ) async {
    var calls = 0;
    final repository = _FakeHistoryRepository(
      calendarHandler: (_, _, _) async {
        calls += 1;
        if (calls == 1) {
          throw const RuntimeHistoryException(
            'server down',
            statusCode: 500,
            kind: 'http',
          );
        }
        return const HistoryCalendarSnapshot(days: [], fromCache: false);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarPage(
          repository: repository,
          initialMonth: DateTime(2026, 9),
          timezoneOffsetMinutes: 480,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('历史加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('calendar day loads UTC+8 range then reuses read-only renderer', (
    tester,
  ) async {
    late DateTime capturedStart;
    late DateTime capturedEnd;
    final supplemental = ChatMessage(
      role: 'assistant',
      content: '补充历史也按真实时间出现',
      time: DateTime.parse('2026-08-13T01:00:00Z'),
      kind: 'legacy_archive',
    );
    final repository = _FakeHistoryRepository(
      calendarHandler: (_, _, _) async => const HistoryCalendarSnapshot(
        days: [HistoryCalendarDay(date: '2026-08-13', messageCount: 1)],
        fromCache: false,
      ),
      dayHandler: (start, end) async {
        capturedStart = start;
        capturedEnd = end;
        return HistoryDaySnapshot(messages: [supplemental], fromCache: true);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarPage(
          repository: repository,
          initialMonth: DateTime(2026, 8),
          timezoneOffsetMinutes: 480,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('calendar-day-2026-08-13')));
    await tester.pumpAndSettle();
    expect(capturedStart, DateTime.parse('2026-08-12T16:00:00Z'));
    expect(capturedEnd, DateTime.parse('2026-08-13T16:00:00Z'));
    expect(find.text('离线缓存'), findsOneWidget);
    expect(find.text('这一天聊了什么'), findsOneWidget);
    expect(find.text('当日归档文件'), findsNothing);

    await tester.tap(find.text('这一天聊了什么'));
    await tester.pumpAndSettle();
    expect(find.byType(ReadOnlyChatViewPage), findsOneWidget);
    expect(find.text('补充历史也按真实时间出现'), findsOneWidget);
  });

  testWidgets('day distinguishes true empty state from retryable error', (
    tester,
  ) async {
    var calls = 0;
    final repository = _FakeHistoryRepository(
      dayHandler: (_, _) async {
        calls += 1;
        if (calls == 1) {
          throw const RuntimeHistoryException('bad json');
        }
        return const HistoryDaySnapshot(messages: [], fromCache: false);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DayPage(
          date: DateTime(2026, 8, 13),
          repository: repository,
          timezoneOffsetMinutes: 480,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('当天消息加载失败'), findsOneWidget);
    expect(find.text('这一天没有消息'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('这一天没有消息'), findsOneWidget);
  });

  testWidgets('calendar and day remain usable at compact phone widths', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final repository = _FakeHistoryRepository(
      calendarHandler: (_, _, _) async => const HistoryCalendarSnapshot(
        days: [HistoryCalendarDay(date: '2026-09-01', messageCount: 1)],
        fromCache: false,
      ),
      dayHandler: (_, _) async => HistoryDaySnapshot(
        messages: [ChatMessage(role: 'user', content: 'compact')],
        fromCache: false,
      ),
    );

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarPage(
            repository: repository,
            initialMonth: DateTime(2026, 9),
            timezoneOffsetMinutes: 480,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'calendar should fit at ${width.toInt()}px',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DayPage(
            date: DateTime(2026, 9, 1),
            repository: repository,
            timezoneOffsetMinutes: 480,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'day should fit at ${width.toInt()}px',
      );
    }
  });
}

Color? _dotColor(WidgetTester tester, String date) {
  final box = tester.widget<SizedBox>(
    find.byKey(ValueKey('calendar-message-dot-$date')),
  );
  final decoration = (box.child! as DecoratedBox).decoration as BoxDecoration;
  return decoration.color;
}
