import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/reading_book.dart';
import 'package:continuum_chat/pages/music_page.dart';
import 'package:continuum_chat/pages/reading_page.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('B1 reading leads with the active book and shared context', (
    tester,
  ) async {
    await _pump(
      tester,
      ReadingPage(booksLoader: ({bool force = false}) async => _readingBooks()),
    );

    expect(find.text('正在一起读'), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-active-海边的卡夫卡')), findsOneWidget);
    expect(find.text('用户读到 第十二章'), findsOneWidget);
    expect(find.text('AI 助手读到 第十章'), findsOneWidget);
    expect(find.text('最近感想 · 用户'), findsOneWidget);
    expect(find.text('这一段像潮水慢慢退下去。'), findsOneWidget);
    expect(find.text('继续读'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('海边的卡夫卡')).dy,
      lessThan(tester.getTopLeft(find.text('等待翻开的书')).dy),
    );
  });

  testWidgets('B1 reading keeps distinct empty and failure states', (
    tester,
  ) async {
    await _pump(
      tester,
      ReadingPage(
        booksLoader: ({bool force = false}) async => const <ReadingBook>[],
      ),
    );
    expect(find.text('共读小屋还是空的'), findsOneWidget);

    await _pump(
      tester,
      ReadingPage(booksLoader: ({bool force = false}) async => null),
    );
    expect(find.text('共读小屋连不上'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('B1 music leads with the shared listening moment', (
    tester,
  ) async {
    await _pump(tester, const MusicPage(skipInitialLoads: true));

    expect(find.text('现在一起听什么'), findsOneWidget);
    expect(find.text('挑一首，让这一刻有同一段声音'), findsOneWidget);
    expect(find.text('还没在听歌'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pump();
    expect(find.text('接下来想听什么'), findsOneWidget);
    for (final label in ['最近播放', '搜索', '我的歌单', '每日推荐']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('B1 pages fit 320 375 414 in light and dark', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      for (final theme in [appTheme.light, appTheme.dark]) {
        for (final page in <Widget>[
          ReadingPage(
            booksLoader: ({bool force = false}) async =>
                _readingBooks(long: true),
          ),
          const MusicPage(skipInitialLoads: true),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              themeAnimationDuration: Duration.zero,
              home: page,
            ),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${page.runtimeType} ${theme.brightness.name} ${width.toInt()}px',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    }
  });
}

List<ReadingBook> _readingBooks({bool long = false}) => [
  ReadingBook(
    title: long ? '一本名字很长很长但仍然适合一起慢慢读完的书' : '海边的卡夫卡',
    author: '村上春树',
    status: '正在看',
    updated: '2026-09-03',
    summary: '',
    participantLastChapter: long ? '第十二章：一段很长的章节名称' : '第十二章',
    assistantLastChapter: '第十章',
    progress: const [],
    notes: const [
      ReadingNote(time: '2026-09-01', who: 'AI 助手', text: '较早的感想'),
      ReadingNote(time: '2026-09-03', who: '用户', text: '这一段像潮水慢慢退下去。'),
    ],
    ratings: const {},
  ),
  const ReadingBook(
    title: '等待翻开的书',
    author: '另一位作者',
    status: '未读',
    updated: '2026-09-02',
    summary: '',
    participantLastChapter: '',
    assistantLastChapter: '',
    progress: [],
    notes: [],
    ratings: {},
  ),
  const ReadingBook(
    title: '已经读完的书',
    author: '',
    status: '已读',
    updated: '2026-08-20',
    summary: '',
    participantLastChapter: '',
    assistantLastChapter: '',
    progress: [],
    notes: [],
    ratings: {},
  ),
];

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pump();
}
