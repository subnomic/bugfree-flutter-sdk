import 'dart:async';

import 'package:flutter/widgets.dart';

import 'client.dart';
import 'event.dart';
import 'options.dart';
import 'stack_trace.dart';

/// The app-wide bugfree client.
///
/// ```dart
/// Future<void> main() async {
///   await Bugfree.init(const BugfreeOptions(
///     dsn: String.fromEnvironment('BUGFREE_DSN'),
///     release: 'shop@1.4.0+42',
///   ));
///   runApp(const ShopApp());
/// }
/// ```
///
/// Before [init], and with an empty DSN, every call is a no-op, so application
/// code is the same in every environment.
abstract final class Bugfree {
  static BugfreeClient _client = BugfreeClient.disabled();

  /// The client the static calls go to.
  static BugfreeClient get client => _client;

  /// Starts reporting: errors Flutter catches, errors nothing caught, the app's
  /// lifecycle and, with a release, the launch as a session.
  ///
  /// Call it at the top of `main`, before `runApp`. A second call replaces the
  /// first client; what the first one already captured is still sent.
  static Future<void> init(BugfreeOptions options) async {
    WidgetsFlutterBinding.ensureInitialized();
    // The package whose main() called this is the application's own code.
    final caller = options.inAppPackages.isEmpty ? callerPackage(StackTrace.current) : null;
    final next = BugfreeClient(options, inAppPackages: {if (caller != null) caller});
    final previous = _client;
    // The previous client's hooks come off first, so the new ones chain to the
    // handlers that were there before either. Its queue is still sent, in the
    // background, instead of being cut off with its HTTP client.
    previous.uninstall();
    _client = next;
    next.install();
    unawaited(previous.close(const Duration(seconds: 10)));
  }

  /// Sends what is still pending and turns reporting off.
  static Future<void> close([Duration timeout = const Duration(seconds: 2)]) async {
    final previous = _client;
    _client = BugfreeClient.disabled();
    await previous.close(timeout);
  }

  /// See [BugfreeClient.captureException].
  static Future<String?> captureException(
    Object error, {
    StackTrace? stackTrace,
    BugfreeLevel level = BugfreeLevel.error,
    String? type,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    String? fingerprint,
  }) =>
      _client.captureException(
        error,
        stackTrace: stackTrace,
        level: level,
        type: type,
        tags: tags,
        extra: extra,
        fingerprint: fingerprint,
      );

  /// See [BugfreeClient.captureMessage].
  static Future<String?> captureMessage(
    String message, {
    BugfreeLevel level = BugfreeLevel.info,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    String? fingerprint,
  }) =>
      _client.captureMessage(message, level: level, tags: tags, extra: extra, fingerprint: fingerprint);

  /// See [BugfreeClient.captureFeedback].
  static Future<bool> captureFeedback({
    required String message,
    String name = '',
    String email = '',
    String? eventId,
  }) =>
      _client.captureFeedback(message: message, name: name, email: email, eventId: eventId);

  static void addBreadcrumb(BugfreeBreadcrumb crumb) => _client.addBreadcrumb(crumb);

  static void setUser(BugfreeUser? user) => _client.setUser(user);

  static void setTag(String key, Object? value) => _client.setTag(key, value);

  static void setExtra(String key, Object? value) => _client.setExtra(key, value);

  static Future<bool> flush([Duration timeout = const Duration(seconds: 2)]) => _client.flush(timeout);

  /// The id of the latest captured event, to show the user as a reference.
  static String? get lastEventId => _client.lastEventId;

  static bool get enabled => _client.enabled;

  /// Replaces the client, for tests; [close] puts a disabled one back.
  @visibleForTesting
  static set client(BugfreeClient client) => _client = client;
}
