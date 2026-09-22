import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef FakeHttpHandler =
    FutureOr<FakeHttpResponseData> Function(FakeHttpRequestData request);

class FakeHttpRequestData {
  FakeHttpRequestData({
    required this.method,
    required this.uri,
    required this.bodyBytes,
    this.headers = const {},
  });

  final String method;

  final Uri uri;
  final List<int> bodyBytes;
  final Map<String, List<String>> headers;

  String get body => utf8.decode(bodyBytes);

  Map<String, dynamic> get jsonBody {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw const FormatException('request body is not a JSON object');
  }
}

class FakeHttpResponseData {
  const FakeHttpResponseData({
    required this.statusCode,
    this.body = '',
    this.bodyStream,
    this.reasonPhrase,
    this.headers = const {},
  });

  factory FakeHttpResponseData.json(
    Map<String, dynamic> body, {
    int statusCode = 200,
    String? reasonPhrase,
    Map<String, String> headers = const {},
  }) {
    return FakeHttpResponseData(
      statusCode: statusCode,
      body: jsonEncode(body),
      reasonPhrase: reasonPhrase,
      headers: headers,
    );
  }

  final int statusCode;
  final String body;
  final Stream<List<int>>? bodyStream;
  final String? reasonPhrase;
  final Map<String, String> headers;
}

class FakeHttpClient implements HttpClient {
  FakeHttpClient(this.handler);

  final FakeHttpHandler handler;
  final List<FakeHttpRequestData> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _FakeHttpClientRequest(method, url, handler, requests);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.method, this.uri, this.handler, this.requests);

  @override
  final String method;

  @override
  final Uri uri;
  final FakeHttpHandler handler;
  final List<FakeHttpRequestData> requests;
  final BytesBuilder _body = BytesBuilder();
  final _HeaderSink _headers = _HeaderSink();

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.add(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    final request = FakeHttpRequestData(
      method: method,
      uri: uri,
      bodyBytes: _body.takeBytes(),
      headers: _headers.values,
    );
    requests.add(request);
    final response = await Future.value(handler(request));
    return _FakeHttpClientResponse(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.response);

  final FakeHttpResponseData response;

  @override
  int get statusCode => response.statusCode;

  @override
  int get contentLength =>
      response.bodyStream == null ? utf8.encode(response.body).length : -1;

  @override
  String get reasonPhrase =>
      response.reasonPhrase ??
      (response.statusCode == 200 ? 'OK' : 'HTTP ${response.statusCode}');

  @override
  HttpHeaders get headers => _HeaderSink({
    'content-type': const ['application/json; charset=utf-8'],
    for (final entry in response.headers.entries)
      entry.key.toLowerCase(): [entry.value],
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
    final stream =
        response.bodyStream ??
        Stream<List<int>>.fromIterable([utf8.encode(response.body)]);
    return stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeaderSink implements HttpHeaders {
  _HeaderSink([Map<String, List<String>>? values])
    : _values = values ?? <String, List<String>>{};

  final Map<String, List<String>> _values;
  Map<String, List<String>> get values => Map.unmodifiable(_values);

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
