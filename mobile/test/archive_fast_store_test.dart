import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/archived_chat.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_store.dart';
// Test-only seam: redirect path_provider to a temporary documents directory.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'archive fast store migrates lazily and recovers from derived corruption',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'continuum-archive-test-',
      );
      final previousProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(temp.path);
      SharedPreferences.setMockInitialValues({});
      addTearDown(() async {
        PathProviderPlatform.instance = previousProvider;
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      final archive = ArchivedChat(
        id: 'archive-1',
        archivedAt: DateTime(2026, 8, 28, 12, 30),
        title: '旧标题',
        messages: [
          ChatMessage(
            role: 'user',
            content: '真正的第一句',
            time: DateTime(2026, 8, 28, 12, 29),
            rawEventId: 42,
          ),
        ],
      );
      await File(
        '${temp.path}/archives.json',
      ).writeAsString(jsonEncode([archive.toJson()]));

      final summaries = await ChatStore.loadArchiveSummaries();
      expect(summaries, hasLength(1));
      expect(summaries.single.title, '真正的第一句');
      expect(summaries.single.messageCount, 1);
      expect(await File('${temp.path}/archive_index.json').exists(), isTrue);
      final body = File('${temp.path}/archive_bodies/archive-1.json');
      expect(await body.exists(), isTrue);

      await File('${temp.path}/archive_index.json').writeAsString('{broken');
      final rebuilt = await ChatStore.loadArchiveSummaries();
      expect(rebuilt, hasLength(1));
      expect(rebuilt.single.id, 'archive-1');

      await body.writeAsString('{broken');
      final loaded = await ChatStore.loadArchiveById('archive-1');
      expect(loaded, isNotNull);
      expect(loaded!.messages.single.content, '真正的第一句');
      expect(loaded.messages.single.rawEventId, 42);

      final repairedBody = jsonDecode(await body.readAsString());
      expect(repairedBody, isA<Map<String, dynamic>>());
      expect(repairedBody['id'], 'archive-1');
    },
  );
}
