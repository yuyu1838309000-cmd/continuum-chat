import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('mutation API uses canonical methods, paths and command ids', () async {
    final seen = <Map<String, dynamic>>[];
    final api = RuntimeHistoryApi(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        seen.add({
          'method': request.method,
          'path': request.url.path,
          'body': body,
        });
        if (request.url.path == '/runtime/archive-folders' &&
            request.method == 'POST') {
          return _json(200, {
            'ok': true,
            'folder': {'folder_id': 'f1', 'name': 'A'},
          });
        }
        if (request.url.path.contains('/runtime/archive-folders/f1') &&
            request.method == 'PATCH') {
          return _json(200, {
            'ok': true,
            'folder': {'folder_id': 'f1', 'name': 'B'},
          });
        }
        if (request.url.path == '/runtime/archive-folders/assign') {
          return _json(200, {'ok': true, 'changed_count': 1});
        }
        if (request.url.path == '/runtime/archive-folders/f1' &&
            request.method == 'DELETE') {
          return _json(200, {'ok': true, 'deleted': true});
        }
        if (request.url.path == '/runtime/epochs/e1' &&
            request.method == 'DELETE') {
          return _json(200, {
            'ok': true,
            'epoch': {'epoch_id': 'e1', 'status': 'deleted'},
          });
        }
        if (request.url.path == '/runtime/epochs/e1/restore') {
          return _json(200, {
            'ok': true,
            'epoch': {'epoch_id': 'e1', 'status': 'closed'},
          });
        }
        return _json(404, {'error': 'unexpected'});
      }),
    );

    await api.createFolder(name: 'A', commandId: 'c1');
    await api.renameFolder(folderId: 'f1', name: 'B', commandId: 'c2');
    await api.assignFolder(epochIds: ['e1'], folderId: 'f1', commandId: 'c3');
    await api.deleteFolder(folderId: 'f1', commandId: 'c4');
    await api.deleteEpoch(epochId: 'e1', commandId: 'c5');
    await api.restoreEpoch(epochId: 'e1', commandId: 'c6');

    expect(seen.map((e) => e['method']), [
      'POST',
      'PATCH',
      'POST',
      'DELETE',
      'DELETE',
      'POST',
    ]);
    expect(seen.map((e) => e['path']), [
      '/runtime/archive-folders',
      '/runtime/archive-folders/f1',
      '/runtime/archive-folders/assign',
      '/runtime/archive-folders/f1',
      '/runtime/epochs/e1',
      '/runtime/epochs/e1/restore',
    ]);
    expect(
      [
        for (final item in seen)
          (item['body'] as Map<String, dynamic>)['command_id'],
      ],
      ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'],
    );
  });

  test('transport retry reuses the exact same mutation body', () async {
    final bodies = <String>[];
    var calls = 0;
    final api = RuntimeHistoryApi(
      client: MockClient((request) async {
        calls += 1;
        bodies.add(request.body);
        if (calls == 1) throw http.ClientException('offline once');
        return _json(200, {
          'ok': true,
          'folder': {'folder_id': 'f1', 'name': 'A'},
        });
      }),
    );

    await api.createFolder(name: 'A', commandId: 'stable-command');
    expect(calls, 2);
    expect(bodies[0], bodies[1]);
    expect(jsonDecode(bodies[1])['command_id'], 'stable-command');
  });

  test(
    'repository maps folder mutations and hides command-id plumbing',
    () async {
      final commandIds = <String>[];
      final repository = RuntimeHistoryRepository(
        api: RuntimeHistoryApi(
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            commandIds.add(body['command_id']?.toString() ?? '');
            if (request.method == 'POST' &&
                request.url.path == '/runtime/archive-folders') {
              return _json(200, {
                'ok': true,
                'folder': {'folder_id': 'server-a', 'name': '新的'},
              });
            }
            if (request.method == 'PATCH') {
              return _json(200, {
                'ok': true,
                'folder': {'folder_id': 'server-a', 'name': '改名'},
              });
            }
            return _json(200, {'ok': true, 'changed_count': 1});
          }),
        ),
      );

      final created = await repository.createFolder(' 新的 ');
      final renamed = await repository.renameFolder('server-a', ' 改名 ');
      await repository.assignFolder([
        'epoch-2',
        'epoch-1',
        'epoch-1',
      ], 'server-a');
      expect(created.folderId, 'server-a');
      expect(created.name, '新的');
      expect(renamed.name, '改名');
      expect(commandIds, hasLength(3));
      expect(commandIds.every((id) => id.startsWith('history-ui-')), isTrue);
      expect(commandIds.toSet(), hasLength(3));
    },
  );
}
