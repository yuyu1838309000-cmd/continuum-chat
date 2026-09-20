import 'package:continuum_chat/services/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds runtime and memory URLs with their own ports', () {
    const config = ServerConfig(
      scheme: 'https',
      host: 'example.test',
      runtimePort: 443,
      memoryPort: 9443,
    );

    final runtimeUri = config.runtimeUri('/chat');
    expect(runtimeUri.toString(), 'https://example.test/chat');
    expect(runtimeUri.port, 443);
    expect(
      config.memoryUri('/recall', {'q': 'notes'}).toString(),
      'https://example.test:9443/recall?q=notes',
    );
  });

  test('validates invalid scheme, host, and port', () {
    expect(const ServerConfig(scheme: 'ftp').validate(), isNotNull);
    expect(
      const ServerConfig(host: 'http://example.test').validate(),
      isNotNull,
    );
    expect(const ServerConfig(runtimePort: 0).validate(), isNotNull);
    expect(const ServerConfig().validate(), isNull);
  });

  test('persists and restores all connection fields', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    const expected = ServerConfig(
      scheme: 'https',
      host: 'chat.example.test',
      runtimePort: 8443,
      memoryPort: 8444,
      token: 'test-token',
    );

    await expected.save(preferences);
    final actual = await ServerConfig.load(preferences);

    expect(actual.scheme, expected.scheme);
    expect(actual.host, expected.host);
    expect(actual.runtimePort, expected.runtimePort);
    expect(actual.memoryPort, expected.memoryPort);
    expect(actual.token, expected.token);
  });
}
