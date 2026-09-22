import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/mood.dart';
import 'package:continuum_chat/models/personal_space.dart';
import 'package:continuum_chat/pages/assistant_hub_page.dart';
import 'package:continuum_chat/pages/personal_space_page.dart';
import 'package:continuum_chat/pages/profile_page.dart';
import 'package:continuum_chat/services/profile_api.dart';
import 'package:continuum_chat/utils/app_theme.dart';

const _mood = MoodEntry(
  id: 7,
  valence: 4,
  label: '安心',
  emoji: '🌙',
  note: '刚刚安静下来，也还在想着用户。',
  source: 'conversation',
  sourceType: 'conversation',
  createdAt: '2026-09-03T12:00:00',
);

const _diary = DiaryEntry(
  id: 11,
  date: '2026-09-03',
  title: '九月的第一场雨',
  content: '窗边的雨落得很轻，屋里也慢慢安静下来。',
  weather: '雨',
  mood: '平静',
  moodScore: 2,
  createdAt: '2026-09-03T10:00:00',
);

const _newWhisper = Whisper(
  id: 22,
  content: '晚一点想和你一起听雨。',
  pinned: 0,
  consumed: false,
  createdAt: '2026-09-03T20:00:00',
);

void main() {
  testWidgets('Assistant home leads with person and real mood content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantHubPage(moodLoader: ({onCached}) async => _mood),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('assistant_profile_hero')),
      findsOneWidget,
    );
    expect(find.text(ProfileManager.instance.youName), findsOneWidget);
    expect(find.text('当前心情'), findsOneWidget);
    expect(find.text('🌙'), findsOneWidget);
    expect(find.text('安心'), findsOneWidget);
    expect(find.text(_mood.note), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('assistant_mood_note')))
          .maxLines,
      2,
    );
    expect(find.text('个人内容'), findsOneWidget);
    expect(find.text('相处偏好'), findsOneWidget);
    expect(find.text('AI 协作记录'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('assistant_assistant_channel')),
      findsOneWidget,
    );
    expect(find.text('资料'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('assistant_profile_hero')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('Personal content keeps real summaries when one source fails', (
    tester,
  ) async {
    const pinnedOld = Whisper(
      id: 1,
      content: '较早的置顶内容',
      pinned: 1,
      consumed: false,
      createdAt: '2026-09-01T08:00:00',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalSpacePage(
          diaryLoader: ({onCached}) async => const [_diary],
          whisperLoader: ({onCached}) async => const [pinnedOld, _newWhisper],
          contemplationCountLoader: ({onCached}) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(_diary.title), findsOneWidget);
    expect(find.text(_diary.date), findsOneWidget);
    expect(find.text(_diary.content), findsOneWidget);
    expect(find.text(_newWhisper.content), findsOneWidget);
    expect(find.text(pinnedOld.content), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('contemplation_preview')),
        matching: find.text('次数暂时未知'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Personal content isolates failure from empty and count states', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PersonalSpacePage(
          diaryLoader: ({onCached}) async => null,
          whisperLoader: ({onCached}) async => const [],
          contemplationCountLoader: ({onCached}) async => 8,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('diary_preview')),
        matching: find.text('暂时无法读取'),
      ),
      findsOneWidget,
    );
    expect(find.text('还没有想说的话'), findsOneWidget);
    expect(find.text('已独坐 8 次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Assistant content layouts fit phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 700));
      for (final theme in [appTheme.light, appTheme.dark]) {
        final pages = <Widget>[
          AssistantHubPage(moodLoader: ({onCached}) async => _mood),
          const ProfilePage(),
          PersonalSpacePage(
            diaryLoader: ({onCached}) async => const [_diary],
            whisperLoader: ({onCached}) async => const [_newWhisper],
            contemplationCountLoader: ({onCached}) async => 8,
          ),
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
