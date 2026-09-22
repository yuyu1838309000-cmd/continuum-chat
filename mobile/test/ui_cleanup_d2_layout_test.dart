import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/config_center_page.dart';
import 'package:continuum_chat/pages/toolbox_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('D2 settings and plugin entry pages fit compact widths', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});

    for (final width in <double>[320, 375, 414]) {
      await binding.setSurfaceSize(Size(width, 760));

      for (final page in <Widget>[
        const ConfigCenterPage(),
        const ToolboxPage(),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(width, 760)),
              child: page,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason:
              '${page.runtimeType} should not overflow at ${width.toInt()}px',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });
}
