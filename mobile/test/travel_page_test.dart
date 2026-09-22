import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/travel_page.dart';
import 'package:continuum_chat/services/travel_api.dart';

void main() {
  test('sorts postcards by parsed local time newest first', () {
    final sorted = sortedTravelPostcardsForDisplay([
      _postcard(id: 1, localTime: '2026-07-23 08:00'),
      _postcard(id: 2, localTime: '2026-08-01 18:30'),
      _postcard(id: 3, localTime: '2026-08-27 09:15'),
    ]);

    expect(sorted.map((p) => p.id), orderedEquals([3, 2, 1]));
  });

  test('falls back to id descending when local time is missing or invalid', () {
    final sorted = sortedTravelPostcardsForDisplay([
      _postcard(id: 5, localTime: ''),
      _postcard(id: 9, localTime: 'not-a-date'),
      _postcard(id: 2, stamp: null),
    ]);

    expect(sorted.map((p) => p.id), orderedEquals([9, 5, 2]));
  });

  testWidgets('shows newest three postcards by default', (tester) async {
    await _pumpTravelPage(
      tester,
      width: 375,
      data: _travelData([
        _postcardJson(id: 1, place: '旧城', localTime: '2026-07-23 08:00'),
        _postcardJson(id: 2, place: '河岸', localTime: '2026-08-01 18:30'),
        _postcardJson(id: 3, place: '山路', localTime: '2026-08-15 07:45'),
        _postcardJson(id: 4, place: '新港', localTime: '2026-08-27 09:15'),
      ]),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('新港'), findsOneWidget);
    expect(find.text('山路'), findsOneWidget);
    expect(find.text('河岸'), findsOneWidget);
    expect(find.text('旧城'), findsNothing);
    expect(
      tester.getTopLeft(find.text('新港')).dy,
      lessThan(tester.getTopLeft(find.text('山路')).dy),
    );
    expect(
      tester.getTopLeft(find.text('山路')).dy,
      lessThan(tester.getTopLeft(find.text('河岸')).dy),
    );
  });

  testWidgets('postcard layout fits at 320 width', (tester) async {
    await _pumpTravelPage(
      tester,
      width: 320,
      data: _travelData([
        _postcardJson(
          id: 4,
          place: '一段很长的山海之间的远方地点名称',
          localTime: '2026-08-27 09:15',
          text: '这是一张很长的旅行明信片正文，用来确认窄屏下地点、时间、正文和附加信息都不会挤出屏幕。',
          surface: '非常非常长的地表描述用于检查 chip 省略',
        ),
        _postcardJson(id: 3, place: '山路', localTime: '2026-08-15 07:45'),
        _postcardJson(id: 2, place: '河岸', localTime: '2026-08-01 18:30'),
      ]),
    );

    expect(
      tester.takeException(),
      isNull,
      reason: 'postcard cards should not overflow at 320px',
    );
  });
}

Postcard _postcard({
  required int id,
  String localTime = '2026-08-01 12:00',
  PostcardStamp? stamp,
}) {
  return Postcard(
    id: id,
    text: '明信片 $id',
    stamp:
        stamp ??
        PostcardStamp(
          place: '地点 $id',
          lat: 0,
          lon: 0,
          elevation: 0,
          localTime: localTime,
          weather: '',
          tempC: null,
          surface: '',
          phase: '',
        ),
    frontImg: '',
  );
}

Map<String, dynamic> _travelData(List<Map<String, dynamic>> postcards) {
  return {
    'postcards': {'items': postcards},
  };
}

Map<String, dynamic> _postcardJson({
  required int id,
  required String place,
  required String localTime,
  String text = '今天的风很轻，路边的光也很安静。',
  String surface = 'trail',
}) {
  return {
    'id': id,
    'text': text,
    'stamp': {
      'place': place,
      'local_time': localTime,
      'weather': 'clear',
      'temp_c': 18.2,
      'elevation': 32,
      'surface': surface,
    },
  };
}

Future<void> _pumpTravelPage(
  WidgetTester tester, {
  required double width,
  required Map<String, dynamic> data,
}) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  addTearDown(() => binding.setSurfaceSize(null));
  await binding.setSurfaceSize(Size(width, 760));
  await tester.pumpWidget(MaterialApp(home: TravelPage(initialData: data)));
  await tester.pump();
}
