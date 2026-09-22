import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/context_layout_page.dart';
import 'package:continuum_chat/pages/gen_image_config_page.dart';
import 'package:continuum_chat/pages/ocr_config_page.dart';
import 'package:continuum_chat/pages/personal_space_page.dart';
import 'package:continuum_chat/pages/search_page.dart';
import 'package:continuum_chat/pages/settings_page.dart';
import 'package:continuum_chat/pages/stt_config_page.dart';
import 'package:continuum_chat/pages/toolbox_page.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:continuum_chat/widgets/memory_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HeaderSink implements HttpHeaders {
  _HeaderSink([Map<String, List<String>>? values])
    : _values = values ?? <String, List<String>>{};

  final Map<String, List<String>> _values;

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    final normalized = preserveHeaderCase ? name : name.toLowerCase();
    _values[normalized] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ContextLayoutHttpClient implements HttpClient {
  _ContextLayoutHttpClient(this.requests);

  final List<String> requests;

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add('$method ${url.path}');
    final body = switch ((method, url.path)) {
      ('GET', '/context-layout') => jsonEncode({
        'blocks': [
          {
            'id': 'identity',
            'label': '身份提示块',
            'enabled': true,
            'position': 'system',
            'rendered_text': '这是一段用于预览的较长中文内容，验证展开动作不会误入详情页。',
          },
          {
            'id': 'time',
            'label': '时间感知',
            'enabled': false,
            'position': 'user_after',
            'source': 'time',
            'rendered_text': '',
          },
        ],
        'last_assembly': const [],
      }),
      ('POST', '/context-layout') => '{}',
      _ => '{}',
    };
    final statusCode = url.path == '/context-layout' ? 200 : 404;
    return _ContextLayoutRequest(
      _ContextLayoutResponse(body: body, statusCode: statusCode),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ContextLayoutRequest implements HttpClientRequest {
  _ContextLayoutRequest(this._response);

  final HttpClientResponse _response;
  final BytesBuilder _body = BytesBuilder();

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  HttpHeaders get headers => _HeaderSink();

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.add(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ContextLayoutResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _ContextLayoutResponse({required this.body, required this.statusCode});

  final String body;

  @override
  final int statusCode;

  @override
  int get contentLength => utf8.encode(body).length;

  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Not Found';

  @override
  HttpHeaders get headers => _HeaderSink({
    'content-type': const ['application/json; charset=utf-8'],
  });

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([utf8.encode(body)]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _mockPlatformState() {
  SharedPreferences.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: 'Continuum Chat',
    packageName: 'app.continuum.frontend',
    version: '0.0.0-test',
    buildNumber: '1',
    buildSignature: '',
  );
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(375, 760),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final theme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4A7C59),
      brightness: brightness,
    ),
    useMaterial3: true,
  );
  await TestWidgetsFlutterBinding.ensureInitialized().setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.only(bottom: 24),
          viewPadding: const EdgeInsets.only(bottom: 24),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child,
      ),
    ),
  );
  await tester.pump();
}

void _expectNoWidgetException(WidgetTester tester, String reason) {
  expect(tester.takeException(), isNull, reason: reason);
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  String? reason,
}) async {
  for (var i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = [
    for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
  ].join(' | ');
  fail('${reason ?? 'Expected $finder to appear'}; visibleText=$visibleText');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings, tool, and list entry pages fit compact text matrix', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    _mockPlatformState();

    for (final width in <double>[320, 375, 414]) {
      for (final textScale in <double>[1, 1.3]) {
        final pages = <({Widget page, Brightness brightness, String label})>[
          (
            page: const SettingsPage(),
            brightness: Brightness.light,
            label: 'settings',
          ),
          (
            page: const ToolboxPage(),
            brightness: Brightness.dark,
            label: 'toolbox',
          ),
          (
            page: const PersonalSpacePage(),
            brightness: Brightness.light,
            label: 'personal space list',
          ),
        ];

        for (final entry in pages) {
          await _pumpApp(
            tester,
            entry.page,
            size: Size(width, 568),
            textScale: textScale,
            brightness: entry.brightness,
          );
          _expectNoWidgetException(
            tester,
            '${entry.label} should fit ${width.toInt()}px at text scale $textScale',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    }
  });

  testWidgets('icon-only clear and key visibility actions are discoverable', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    _mockPlatformState();

    await _pumpApp(
      tester,
      SearchPage(
        currentMessages: const [],
        debounceDuration: const Duration(days: 1),
      ),
      size: const Size(320, 568),
      textScale: 1.3,
    );
    await tester.enterText(find.byType(TextField), '搜索');
    await tester.pump();
    expect(find.byTooltip('清空搜索'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('清空搜索')).shortestSide,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(find.text('输入关键词，搜咱们聊过的内容'), findsOneWidget);

    for (final page in <Widget>[
      const OcrConfigPage(),
      const SttConfigPage(),
      const GenImageConfigPage(),
    ]) {
      _mockPlatformState();
      await _pumpApp(tester, page, size: const Size(320, 568), textScale: 1.3);
      await tester.pump();
      expect(
        find.byTooltip('显示 API Key'),
        findsOneWidget,
        reason: '${page.runtimeType} key visibility icon needs a tooltip',
      );
      expect(
        tester.getSize(find.byTooltip('显示 API Key')).shortestSide,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.byTooltip('显示 API Key'));
      await tester.pump();
      expect(find.byTooltip('隐藏 API Key'), findsOneWidget);
      _expectNoWidgetException(
        tester,
        '${page.runtimeType} key visibility action should not overflow',
      );
    }
  });

  testWidgets('folder dialog stays usable above keyboard and safe area', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    _mockPlatformState();
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);

    await _pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () {
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('一个很长很长的中文确认标题'),
                      content: const SingleChildScrollView(
                        child: Text(
                          '这是一段很长的中文对话框正文，用来验证键盘弹出和底部手势安全区同时存在时，内容不会横向溢出。',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: const Text('打开确认对话框'),
            ),
          ),
        ),
      ),
      size: const Size(320, 568),
      textScale: 1.3,
    );

    await tester.tap(find.text('打开确认对话框'));
    await _pumpUntilFound(
      tester,
      find.text('一个很长很长的中文确认标题'),
      reason: 'dialog should appear above keyboard',
    );

    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    _expectNoWidgetException(
      tester,
      'dialog should fit above keyboard and safe area',
    );
    Navigator.of(
      tester.element(find.text('一个很长很长的中文确认标题')),
      rootNavigator: true,
    ).pop();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'memory edit bottom sheet handles keyboard, long errors, loading',
    (tester) async {
      _resetViewAfterTest(tester);
      _mockPlatformState();
      tester.view.padding = const FakeViewPadding(bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);

      var saveCalls = 0;
      final pending = Completer<MemoryEditResult>();
      await _pumpApp(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<MemoryEditResult>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => MemoryEditSheet(
                    titleLabel: '新增记忆',
                    confirmLabel: '保存',
                    onSave: (_, _) {
                      saveCalls += 1;
                      return pending.future;
                    },
                  ),
                ),
                child: const Text('打开记忆编辑'),
              ),
            ),
          ),
        ),
        size: const Size(320, 568),
        textScale: 1.3,
      );

      await tester.tap(find.text('打开记忆编辑'));
      await _pumpUntilFound(
        tester,
        find.text('新增记忆'),
        reason: 'memory edit sheet should appear',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump(const Duration(milliseconds: 220));
      await tester.enterText(find.byType(TextField).last, '一条不会为空的记忆正文');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.tap(find.byType(CircularProgressIndicator).last);
      await tester.pump();

      expect(saveCalls, 1);
      _expectNoWidgetException(
        tester,
        'memory edit loading state should not overflow or resubmit',
      );

      pending.complete(
        const MemoryEditResult(
          saved: false,
          message: '保存失败：这是一段很长很长的中文错误信息，用来验证窄屏和键盘弹出时不会横向溢出，也不会把底部主动作遮住。',
        ),
      );
      await _pumpUntilFound(
        tester,
        find.textContaining('保存失败'),
        reason: 'long memory error should appear',
      );

      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      _expectNoWidgetException(
        tester,
        'long memory edit error should wrap on compact keyboard layout',
      );
      Navigator.of(tester.element(find.text('新增记忆'))).pop();
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets('context layout card child actions do not open the detail page', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    _mockPlatformState();
    await ServerConfig.instance.setHost('127.0.0.1');
    final requests = <String>[];

    await HttpOverrides.runZoned(() async {
      await _pumpApp(
        tester,
        const ContextLayoutPage(),
        size: const Size(320, 568),
        textScale: 1.3,
        brightness: Brightness.dark,
      );
      await _pumpUntilFound(
        tester,
        find.text('身份提示块'),
        reason: 'context layout cards should load; requests=$requests',
      );

      expect(find.text('身份提示块'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('保存'), findsNothing);

      await tester.tap(find.byTooltip('下移').first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('保存'), findsNothing);

      expect(find.textContaining('真正送给模型'), findsOneWidget);
      await tester.tap(find.text('配置预览').last);
      await _pumpUntilFound(
        tester,
        find.textContaining('用于预览'),
        reason: 'preview should expand inline',
      );
      expect(find.textContaining('用于预览'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      _expectNoWidgetException(
        tester,
        'context layout child actions should not trigger card navigation',
      );
    }, createHttpClient: (_) => _ContextLayoutHttpClient(requests));

    expect(requests, contains('GET /context-layout'));
    expect(requests, contains('POST /context-layout'));
  });
}

void _resetViewAfterTest(WidgetTester tester) {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  addTearDown(() async {
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
    await binding.setSurfaceSize(null);
  });
}
