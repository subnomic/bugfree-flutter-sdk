import 'package:http/http.dart' as http;

import 'bugfree.dart';
import 'client.dart';
import 'event.dart';

/// An HTTP client that records every request as a breadcrumb: method, address
/// without its query string, status and duration.
///
/// ```dart
/// final api = BugfreeHttpClient(http.Client());
/// final response = await api.get(Uri.parse('https://api.example.com/orders'));
/// ```
///
/// The query string is left out, since tokens and personal data travel there.
class BugfreeHttpClient extends http.BaseClient {
  /// Wraps [inner]; records to [client], or to the [Bugfree] client when null.
  BugfreeHttpClient(this.inner, {BugfreeClient? client}) : _client = client;

  final http.Client inner;
  final BugfreeClient? _client;

  BugfreeClient get _target => _client ?? Bugfree.client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final target = _target;
    final base = target.ingestBase;
    // The SDK's own deliveries would describe themselves.
    if (!target.enabled || (base != null && request.url.toString().startsWith(base))) {
      return inner.send(request);
    }

    final started = DateTime.now();
    final url = request.url;
    final address = '${url.scheme}://${url.authority}${url.path}';
    try {
      final response = await inner.send(request);
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      target.addBreadcrumb(BugfreeBreadcrumb(
        category: 'http',
        message: '${request.method} $address → ${response.statusCode}',
        level: response.statusCode >= 500 ? 'error' : (response.statusCode >= 400 ? 'warning' : 'info'),
        data: '$elapsed ms',
      ));
      return response;
    } catch (error) {
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      target.addBreadcrumb(BugfreeBreadcrumb(
        category: 'http',
        message: '${request.method} $address failed: ${error.runtimeType}',
        level: 'error',
        data: '$elapsed ms',
      ));
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}
