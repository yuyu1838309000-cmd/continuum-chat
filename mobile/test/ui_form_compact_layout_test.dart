import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/prompt_entry.dart';
import 'package:continuum_chat/pages/section_items_page.dart';

void main() {
  testWidgets('section item editor fits 320px with keyboard insets', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() {
      tester.view.resetViewInsets();
      return binding.setSurfaceSize(null);
    });

    await binding.setSurfaceSize(const Size(320, 568));
    final section = PromptSection(title: '一个很长的分区标题', items: []);

    await tester.pumpWidget(
      MaterialApp(home: SectionItemsPage(section: section)),
    );
    await tester.tap(find.byTooltip('新增条目').last);
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'bottom sheet should stay within compact keyboard layout',
    );
    expect(find.text('新增条目'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '紧凑标题');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('紧凑标题'), findsOneWidget);
  });
}
