import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/extension_config_api.dart';

import 'support/fake_http.dart';

void main() {
  test('MCP config secret helpers detect masked and sensitive fields', () {
    expect(
      ExtensionConfigApi.isSecretConfiguredValue(
        ExtensionConfigApi.mcpSecretConfiguredValue,
      ),
      isTrue,
    );
    expect(ExtensionConfigApi.isSecretConfigKey('Authorization'), isTrue);
    expect(ExtensionConfigApi.isSecretConfigKey('SUPABASE_API_KEY'), isTrue);
    expect(ExtensionConfigApi.isSecretConfigKey('LOG_LEVEL'), isFalse);
  });

  test(
    'mcpToolsResult preserves non-200 status and backend error body',
    () async {
      late final FakeHttpClient client;
      client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/mcp/tools');
        expect(request.uri.queryParameters['server'], 'missing');
        return FakeHttpResponseData.json({
          'error': 'server missing',
        }, statusCode: 404);
      });

      final result = await HttpOverrides.runZoned(
        () => ExtensionConfigApi.mcpToolsResult('missing'),
        createHttpClient: (_) => client,
      );

      expect(result, isNotNull);
      expect(result, containsPair('ok', false));
      expect(result, containsPair('status', 404));
      expect(result, containsPair('error', 'server missing'));
    },
  );
}
