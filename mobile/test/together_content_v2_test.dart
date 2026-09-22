import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/reading_book.dart';
import 'package:continuum_chat/pages/together_hub_page.dart';
import 'package:continuum_chat/services/together_summary_service.dart';
import 'package:continuum_chat/utils/app_theme.dart';

void main() {
  test('summary adapters keep only the highest-value real state', () {
    final home = TogetherSummaryService.parseHome({
      'me': {'room': 'living', 'action': '听雨'},
      'appUser': {'room': 'out', 'action': ''},
      'cat': {'room': 'balcony', 'action': '晒太阳'},
    });
    expect(home?.people.first.room, '客厅');
    expect(home?.people[1].room, '出门了');

    final reading = TogetherSummaryService.parseReading({
      'finished': {'title': '已经读完', 'status': '已读', 'updated': '2026-09-03'},
      'older': {'title': '较早在读', 'status': '正在看', 'updated': '2026-09-01'},
      'latest': {
        'title': '最近在读',
        'author': '作者',
        'status': '正在看',
        'updated': '2026-09-02',
      },
    });
    expect(reading?.book?.title, '最近在读');
    expect(reading?.activeCount, 2);

    final journey = TogetherSummaryService.parseTravel({
      'journey': {'place_name': '冰岛', 'last_text': '刚刚落地。'},
      'postcards': {
        'items': [
          {'id': 9, 'text': '这张不应优先'},
        ],
      },
    });
    expect(journey?.title, '冰岛');
    expect(journey?.fromPostcard, isFalse);

    final postcard = TogetherSummaryService.parseTravel({
      'journey': <String, dynamic>{},
      'postcards': {
        'items': [
          {'id': 1, 'text': '旧明信片'},
          {
            'id': 2,
            'text': '新明信片',
            'stamp': {'place': '赫尔辛基', 'local_time': '2026-09-02 12:00'},
          },
          {
            'id': 99,
            'text': 'id 更大但时间更早',
            'stamp': {'place': '旧地点', 'local_time': '2026-09-01 12:00'},
          },
        ],
      },
    });
    expect(postcard?.title, '赫尔辛基');
    expect(postcard?.detail, '新明信片');
    expect(postcard?.fromPostcard, isTrue);
  });

  testWidgets('Together home leads with real shared activity summaries', (
    tester,
  ) async {
    final music = ChangeNotifier();
    await tester.pumpWidget(
      MaterialApp(
        home: _togetherPage(
          music: music,
          home: const TogetherHomeSummary([
            TogetherHomePersonSummary(name: 'AI 助手', room: '客厅', action: '听雨'),
            TogetherHomePersonSummary(name: '用户', room: '厨房', action: '煮茶'),
            TogetherHomePersonSummary(name: '猫咪', room: '阳台', action: '晒太阳'),
          ]),
          reading: TogetherReadingSummary(
            book: _book(
              title: '海边的卡夫卡',
              author: '村上春树',
              participantLastChapter: '第十二章',
            ),
            activeCount: 2,
          ),
          travel: const TogetherTravelSummary(
            title: '雷克雅未克',
            detail: '风从海湾一路吹过来。',
            fromPostcard: false,
          ),
          musicSummary: const TogetherMusicSummary(
            title: 'Mystery of Love',
            artist: 'Sufjan Stevens',
            playing: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('together_home_hero')), findsOneWidget);
    expect(find.text('客厅 · 听雨'), findsOneWidget);
    expect(find.text('Mystery of Love'), findsOneWidget);
    expect(find.text('Sufjan Stevens · 正在播放'), findsOneWidget);
    expect(find.text('海边的卡夫卡'), findsOneWidget);
    expect(find.textContaining('另有 1 本正在看'), findsOneWidget);
    expect(find.text('雷克雅未克'), findsOneWidget);
    expect(find.text('风从海湾一路吹过来。'), findsOneWidget);
    expect(find.text('提问瓶'), findsOneWidget);
    expect(find.textContaining('点击查看'), findsNothing);
  });

  testWidgets('summary sources load and degrade independently', (tester) async {
    final homeResult = Completer<TogetherHomeSummary?>();
    final readingResult = Completer<TogetherReadingSummary?>();
    final travelResult = Completer<TogetherTravelSummary?>();
    final music = ChangeNotifier();

    await tester.pumpWidget(
      MaterialApp(
        home: TogetherHubPage(
          homeLoader: ({onCached}) => homeResult.future,
          readingLoader: ({onCached}) => readingResult.future,
          travelLoader: ({onCached}) => travelResult.future,
          musicListenable: music,
          musicReader: () => const TogetherMusicSummary.empty(),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('home_loading')), findsOneWidget);
    expect(find.text('正在读取'), findsNWidgets(2));
    expect(find.text('还没有在播放'), findsOneWidget);

    homeResult.completeError(StateError('offline'));
    readingResult.complete(
      const TogetherReadingSummary(book: null, activeCount: 0),
    );
    travelResult.complete(const TogetherTravelSummary.empty());
    await tester.pump();

    expect(find.text('暂时没读到家里的动静'), findsOneWidget);
    expect(find.text('还没有正在看的书'), findsOneWidget);
    expect(find.text('还没有新的旅途'), findsOneWidget);
    expect(find.text('提问瓶'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cached summary appears immediately and survives refresh failure',
    (tester) async {
      final refresh = Completer<TogetherHomeSummary?>();
      final cached = const TogetherHomeSummary([
        TogetherHomePersonSummary(name: '用户', room: '卧室', action: '看书'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: TogetherHubPage(
            homeLoader: ({onCached}) {
              onCached?.call(cached);
              return refresh.future;
            },
            readingLoader: ({onCached}) async =>
                const TogetherReadingSummary(book: null, activeCount: 0),
            travelLoader: ({onCached}) async =>
                const TogetherTravelSummary.empty(),
            musicListenable: ChangeNotifier(),
            musicReader: () => const TogetherMusicSummary.empty(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('卧室 · 看书'), findsOneWidget);
      expect(find.byKey(const ValueKey('home_loading')), findsNothing);

      refresh.complete(null);
      await tester.pump();
      expect(find.text('卧室 · 看书'), findsOneWidget);
    },
  );

  testWidgets('Together content fits phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      for (final theme in [appTheme.light, appTheme.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            home: _togetherPage(
              music: ChangeNotifier(),
              home: const TogetherHomeSummary([
                TogetherHomePersonSummary(
                  name: 'AI 助手',
                  room: '游戏房',
                  action: '整理一份很长的旅行照片清单',
                ),
                TogetherHomePersonSummary(
                  name: '用户',
                  room: '厨房',
                  action: '准备晚饭',
                ),
                TogetherHomePersonSummary(name: '猫咪', room: '阳台', action: '睡觉'),
              ]),
              reading: TogetherReadingSummary(
                book: _book(title: '一本书名很长很长的共同读物', author: '作者名字'),
                activeCount: 3,
              ),
              travel: const TogetherTravelSummary(
                title: '一个很长很长的当前位置名称',
                detail: '这是一段用于验证窄屏布局不会溢出的最近旅行文字。',
                fromPostcard: false,
              ),
              musicSummary: const TogetherMusicSummary(
                title: '一首名字很长很长的正在播放的歌曲',
                artist: '歌手名字',
                playing: true,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: '${theme.brightness.name} ${width.toInt()}px',
        );
      }
    }
  });
}

TogetherHubPage _togetherPage({
  required ChangeNotifier music,
  required TogetherHomeSummary home,
  required TogetherReadingSummary reading,
  required TogetherTravelSummary travel,
  required TogetherMusicSummary musicSummary,
}) {
  return TogetherHubPage(
    homeLoader: ({onCached}) async => home,
    readingLoader: ({onCached}) async => reading,
    travelLoader: ({onCached}) async => travel,
    musicListenable: music,
    musicReader: () => musicSummary,
  );
}

ReadingBook _book({
  required String title,
  required String author,
  String participantLastChapter = '',
}) {
  return ReadingBook(
    title: title,
    author: author,
    status: '正在看',
    updated: '2026-09-03',
    summary: '',
    participantLastChapter: participantLastChapter,
    assistantLastChapter: '',
    progress: const [],
    notes: const [],
    ratings: const {},
  );
}
