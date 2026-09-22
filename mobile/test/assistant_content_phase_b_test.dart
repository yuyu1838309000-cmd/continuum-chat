import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/personal_space.dart';
import 'package:continuum_chat/pages/contemplation_page.dart';
import 'package:continuum_chat/pages/diary_detail_page.dart';
import 'package:continuum_chat/pages/diary_list_page.dart';
import 'package:continuum_chat/pages/diary_overview_page.dart';
import 'package:continuum_chat/pages/whisper_list_page.dart';
import 'package:continuum_chat/utils/app_theme.dart';

const _latestDiary = DiaryEntry(
  id: 12,
  date: '2026-09-03',
  title: '九月的第一场雨',
  content: '窗边的雨落得很轻，屋里也慢慢安静下来。',
  weather: '小雨转阴',
  mood: '平静',
  moodScore: 2,
  createdAt: '2026-09-03T10:00:00',
);

const _olderDiary = DiaryEntry(
  id: 11,
  date: '2026-09-01',
  title: '夜里的灯',
  content: '留了一盏很小的灯。',
  weather: '晴',
  mood: '安心',
  moodScore: 7,
  createdAt: '2026-09-01T22:00:00',
);

const _consumedWhisper = Whisper(
  id: 22,
  content: '晚一点想和你一起听雨。',
  pinned: 1,
  consumed: true,
  createdAt: '2026-09-03T20:00:00',
);

const _sameDayWhisper = Whisper(
  id: 21,
  content: '回来的路上看见了月亮。',
  pinned: 0,
  consumed: false,
  createdAt: '2026-09-03T18:00:00',
);

void main() {
  testWidgets('diary list leads with one entry and opens a reading page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DiaryListPage(
          loader: ({bool force = false}) async => const [
            _latestDiary,
            _olderDiary,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('featured_diary_entry')), findsOneWidget);
    expect(find.text(_latestDiary.title), findsOneWidget);
    expect(find.text(_latestDiary.weather), findsOneWidget);
    expect(find.text(_latestDiary.mood), findsOneWidget);
    expect(find.text(_olderDiary.title), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(_latestDiary.title)).dy,
      lessThan(tester.getTopLeft(find.text(_olderDiary.title)).dy),
    );

    await tester.tap(find.text(_olderDiary.title));
    await tester.pumpAndSettle();
    expect(find.byType(DiaryDetailPage), findsOneWidget);
    expect(find.byKey(const ValueKey('diary_body')), findsOneWidget);
  });

  testWidgets('diary detail keeps metadata quiet and omits empty-body copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: DiaryDetailPage(entry: _latestDiary)),
    );

    expect(find.text(_latestDiary.title), findsOneWidget);
    expect(find.text(_latestDiary.date), findsOneWidget);
    expect(find.text(_latestDiary.weather), findsOneWidget);
    expect(find.text(_latestDiary.mood), findsOneWidget);
    expect(find.text(_latestDiary.content), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: DiaryDetailPage(
          entry: DiaryEntry(
            id: 99,
            date: '2026-09-03',
            title: '',
            content: '',
            weather: '',
            mood: '',
            moodScore: null,
            createdAt: '',
          ),
        ),
      ),
    );

    expect(find.text('无题'), findsOneWidget);
    expect(find.text('（这篇日记没有正文）'), findsNothing);
    expect(find.byKey(const ValueKey('diary_body')), findsNothing);
  });

  testWidgets(
    'whispers retain pin and consumed state without backend wording',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WhisperListPage(
            loader: ({bool force = false}) async => const [
              _sameDayWhisper,
              _consumedWhisper,
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('latest_whisper')), findsOneWidget);
      expect(find.text(_consumedWhisper.content), findsOneWidget);
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('已注入'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('latest_whisper')));
      await tester.pumpAndSettle();
      expect(find.text(_consumedWhisper.content), findsOneWidget);
      expect(find.text(_sameDayWhisper.content), findsOneWidget);
      expect(find.text('已注入'), findsNothing);
    },
  );

  testWidgets('contemplation exposes only the room and a real count', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ContemplationPage(countLoader: ({onCached}) async => 8),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('沉思室'), findsOneWidget);
    expect(find.text('这里记录 AI 助手的独立思考。'), findsOneWidget);
    expect(find.text('已独坐 8 次'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ListView), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: ContemplationPage(
          key: const ValueKey('missing_contemplation_count'),
          countLoader: ({onCached}) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contemplation_count')), findsNothing);
    expect(find.textContaining('…'), findsNothing);
  });

  testWidgets('Phase B pages fit compact phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 700));
      for (final theme in [appTheme.light, appTheme.dark]) {
        final pages = <Widget>[
          DiaryListPage(
            loader: ({bool force = false}) async => const [
              _latestDiary,
              _olderDiary,
            ],
          ),
          const DiaryDetailPage(entry: _latestDiary),
          const DiaryOverviewPage(entries: [_latestDiary, _olderDiary]),
          WhisperListPage(
            loader: ({bool force = false}) async => const [
              _consumedWhisper,
              _sameDayWhisper,
            ],
          ),
          ContemplationPage(countLoader: ({onCached}) async => 8),
        ];

        for (final page in pages) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              themeAnimationDuration: Duration.zero,
              home: page,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.runtimeType} should fit ${width.toInt()}px',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    }
  });
}
