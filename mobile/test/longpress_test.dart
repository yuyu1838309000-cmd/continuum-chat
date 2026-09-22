import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selectable text longpress vs outer gesture', (tester) async {
    var outerFired = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            onLongPress: () => outerFired++,
            child: Align(
              alignment: Alignment.center,
              child: SelectableText('hello world'),
            ),
          ),
        ),
      ),
    );
    // 长按文字中心
    await tester.longPress(find.text('hello world'));
    await tester.pumpAndSettle();
    debugPrint('outer longpress fired: $outerFired');
  });
}
