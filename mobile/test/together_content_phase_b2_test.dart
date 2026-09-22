import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/bottle.dart';
import 'package:continuum_chat/pages/bottle_page.dart';
import 'package:continuum_chat/pages/travel_page.dart';
import 'package:continuum_chat/utils/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('B2 travel leads with current journey and recent moments', (
    tester,
  ) async {
    await _pump(tester, TravelPage(initialData: _travelData()));

    expect(find.text('现在走到哪里'), findsOneWidget);
    expect(find.text('青岛海边'), findsOneWidget);
    expect(find.text('最近明信片'), findsOneWidget);
    expect(find.text('从海边寄回来的一句话。'), findsOneWidget);
    expect(find.text('最近见闻'), findsOneWidget);
    expect(find.textContaining('海鸥'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pump();
    expect(find.text('旅途足迹'), findsOneWidget);
  });

  testWidgets('B2 bottle puts the current question before history', (
    tester,
  ) async {
    await _pump(
      tester,
      BottlePage(dataLoader: ({bool force = false}) async => _bottleData()),
    );

    expect(find.text('今天想问你'), findsOneWidget);
    expect(find.text('AI 助手留了一张小纸条'), findsOneWidget);
    expect(find.text('你最近最想一起做什么？'), findsOneWidget);
    expect(find.text('最近聊过'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pump();
    expect(find.text('按话题翻翻'), findsOneWidget);
    expect(find.text('喜好'), findsOneWidget);
  });

  testWidgets('B2 bottle keeps empty and failure states distinct', (
    tester,
  ) async {
    await _pump(
      tester,
      BottlePage(
        dataLoader: ({bool force = false}) async => const BottleData(),
      ),
    );
    expect(find.text('这一轮暂时没有新问题'), findsOneWidget);
    expect(find.text('瓶子空了'), findsOneWidget);

    await _pump(
      tester,
      BottlePage(dataLoader: ({bool force = false}) async => null),
    );
    expect(find.text('提问瓶连不上'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
  testWidgets('B2 pages fit 320 375 414 in light and dark', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));
      for (final theme in [appTheme.light, appTheme.dark]) {
        for (final page in <Widget>[
          TravelPage(initialData: _travelData(long: true)),
          BottlePage(
            dataLoader: ({bool force = false}) async => _bottleData(long: true),
          ),
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

BottleData _bottleData({bool long = false}) => BottleData(
  dimensions: const [BottleDimension(name: '喜好', total: 5, unanswered: 1)],
  latestUnanswered: BottleQuestion(
    id: 11,
    dimension: '关系',
    question: long ? '如果今天什么都不用管，你最想和AI 助手一起去做一件什么很长很长的事情？' : '你最近最想一起做什么？',
    status: '未答',
  ),
  answeredRecent: const [
    BottleQuestion(
      id: 10,
      dimension: '日常',
      question: '最近哪一刻最开心？',
      answer: '一起听歌的时候。',
      status: '已回答',
      answeredAt: '2026-09-02 20:10',
    ),
  ],
);
Map<String, dynamic> _travelData({bool long = false}) => {
  'journey': {
    'place_name': long ? '一个名字很长很长但仍然应该安静显示的青岛海边地点' : '青岛海边',
    'mode': '散步',
    'biome': '海岸',
    'pos': [36.06, 120.38],
    'landed_at': '2026-09-03T06:00:00Z',
    'last_text': long ? '海风很大，这是一段为了验证窄屏布局不会溢出的比较长的当前位置描述。' : '海风很大。',
  },
  'visits': {'青岛': 3, '上海': 2},
  'postcards': {
    'items': [
      {
        'id': 2,
        'text': '从海边寄回来的一句话。',
        'stamp': {
          'place': '青岛',
          'local_time': '2026-09-03 14:30',
          'weather': '晴',
          'temp_c': 24.0,
          'surface': '海岸',
        },
      },
    ],
  },
  'sightings': {
    'items': [
      {
        'name': 'Larus',
        'common_name': '海鸥',
        'distance_m': 18,
        'seen_at': '14:20',
      },
    ],
  },
  'landings': {
    'beijing': {
      'place': '北京',
      'count': 4,
      'elevation': 40,
      'surface': '城市',
      'last': '2026-09-01T08:00:00Z',
    },
  },
};

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pump();
}
