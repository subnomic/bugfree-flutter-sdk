import 'package:http/http.dart' as http;

import 'event.dart';

/// Edits an event before it is sent, or returns null to drop it.
typedef BeforeSend = BugfreeEvent? Function(BugfreeEvent event);

/// The settings of a [BugfreeClient].
class BugfreeOptions {
  const BugfreeOptions({
    this.dsn = '',
    this.environment = 'production',
    this.release = '',
    this.commit = '',
    this.sampleRate = 1,
    this.maxBreadcrumbs = 30,
    this.dedupeWindow = const Duration(seconds: 10),
    this.ignoreErrors = const [],
    this.inAppPackages = const [],
    this.trackSessions = true,
    this.sessionTimeout = const Duration(seconds: 30),
    this.captureFlutterErrors = true,
    this.capturePlatformErrors = true,
    this.debugPrintBreadcrumbs = true,
    this.maxQueueSize = 100,
    this.httpClient,
    this.beforeSend,
    this.debug = false,
  });

  /// `http://<key>@host:3000/ingest`; empty turns the SDK off, every call a no-op.
  final String dsn;

  /// The environment tag.
  final String environment;

  /// The release, used for grouping, regressions and release health:
  /// `shop@1.4.0+42`.
  final String release;

  /// The commit the app was built from; the issue page names it, and an editor
  /// link template can open the file at that revision.
  final String commit;

  /// The share of events sent, between 0 and 1.
  final double sampleRate;

  /// How many breadcrumbs an event carries at most.
  final int maxBreadcrumbs;

  /// The same error is sent once inside this window.
  final Duration dedupeWindow;

  /// Errors to drop: a [String] matches anywhere in "Type: message", a [RegExp]
  /// is tested against it.
  final List<Pattern> ignoreErrors;

  /// The packages that are the application's own code. Empty, the package that
  /// called [Bugfree.init] is taken.
  final List<String> inAppPackages;

  /// Counts every launch of the app as a session of the release, for release health.
  final bool trackSessions;

  /// An app that comes back after this long in the background starts a new session.
  final Duration sessionTimeout;

  /// Reports the errors Flutter catches while building, laying out and painting.
  final bool captureFlutterErrors;

  /// Reports the errors nothing caught, through `PlatformDispatcher.onError`.
  final bool capturePlatformErrors;

  /// Records what `debugPrint` writes as breadcrumbs.
  final bool debugPrintBreadcrumbs;

  /// How many events wait for their turn at most; beyond it new ones are dropped.
  final int maxQueueSize;

  /// The HTTP client the events are sent with; one of its own when null.
  final http.Client? httpClient;

  /// Edits an event before it is sent, or returns null to drop it.
  final BeforeSend? beforeSend;

  /// Writes SDK problems to the console.
  final bool debug;
}
