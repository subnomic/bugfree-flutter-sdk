/// The addresses a DSN (`http://<key>@host[/ingest]`) stands for.
class Dsn {
  Dsn._(this.publicKey, this.base);

  /// The project key, the user part of the DSN.
  final String publicKey;

  /// `scheme://host/ingest/v1/<key>`, which every endpoint starts with.
  final String base;

  Uri get storeUrl => Uri.parse('$base/store');
  Uri get feedbackUrl => Uri.parse('$base/feedback');
  Uri get sessionsUrl => Uri.parse('$base/sessions');

  /// Parses a DSN; null when it is empty or malformed, which leaves the SDK off.
  static Dsn? parse(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final Uri uri;
    try {
      uri = Uri.parse(value.trim());
    } on FormatException {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.userInfo.isEmpty || uri.host.isEmpty) return null;

    // The key is the user part alone; "key:secret" keeps only the key.
    final key = uri.userInfo.split(':').first;
    if (key.isEmpty) return null;

    var path = uri.path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (path.isEmpty) path = 'ingest';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return Dsn._(key, '${uri.scheme}://${uri.host}$port/$path/v1/$key');
  }
}
