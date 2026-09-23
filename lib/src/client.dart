import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'breadcrumbs.dart';
import 'dsn.dart';
import 'event.dart';
import 'options.dart';
import 'platform_web.dart' if (dart.library.io) 'platform_io.dart';
import 'stack_trace.dart';
import 'transport.dart';

/// The version of this SDK; raised with the other SDKs at every release.
const sdkVersion = '0.9.6';

/// Reports errors from one Flutter application to one bugfree project.
///
/// Most apps use the [Bugfree] facade, which holds one client for the whole app;
/// a client of its own is for tests, or for reporting to a second project.
class BugfreeClient with WidgetsBindingObserver {
  /// A client for [options]; with an empty or malformed DSN it is disabled and
  /// every call returns at once.
  factory BugfreeClient(BugfreeOptions options, {Set<String> inAppPackages = const {}}) {
    final dsn = Dsn.parse(options.dsn);
    return BugfreeClient._(options, dsn, {...options.inAppPackages, ...inAppPackages});
  }

  /// A client that sends nothing.
  factory BugfreeClient.disabled() => BugfreeClient._(const BugfreeOptions(), null, const {});

  BugfreeClient._(this.options, this._dsn, this._inAppPackages)
      : _breadcrumbs = BreadcrumbBuffer(options.maxBreadcrumbs) {
    final dsn = _dsn;
    if (dsn == null) return;
    _http = options.httpClient ?? http.Client();
    _ownsHttp = options.httpClient == null;
    _transport = Transport(
      dsn.storeUrl,
      client: _http!,
      maxQueueSize: options.maxQueueSize,
      log: options.debug ? _log : null,
    );
  }

  final BugfreeOptions options;
  final Dsn? _dsn;
  final Set<String> _inAppPackages;
  final BreadcrumbBuffer _breadcrumbs;
  http.Client? _http;
  bool _ownsHttp = false;
  Transport? _transport;

  final Map<String, dynamic> _tags = {};
  final Map<String, dynamic> _extra = {};
  BugfreeUser? _user;
  String? _lastEventId;
  final Map<String, DateTime> _seen = {};
  final Set<Future<void>> _inProgress = {};

  _Session? _session;
  DateTime? _backgroundedAt;
  bool _installed = false;
  bool _closed = false;

  // What install() replaced, put back by close().
  FlutterExceptionHandler? _previousFlutterHandler;
  bool Function(Object, StackTrace)? _previousPlatformHandler;
  DebugPrintCallback? _previousDebugPrint;

  /// Whether this client sends anything.
  bool get enabled => _transport != null && !_closed;

  /// The application's packages, whose frames count as your code.
  Set<String> get inAppPackages => Set.unmodifiable(_inAppPackages);

  /// Who is using the app, as [setUser] set it.
  BugfreeUser? get user => _user;

  /// The id of the latest captured event, known as soon as the capture call returns.
  String? get lastEventId => _lastEventId;

  /// The address events are sent to, which the HTTP breadcrumbs leave out.
  String? get ingestBase => _dsn?.base;

  void _log(String message) {
    if (options.debug) debugPrintSynchronously('[bugfree] $message');
  }

  /// Hooks into Flutter: errors Flutter catches, errors nothing caught,
  /// `debugPrint`, the app's lifecycle and, with [BugfreeOptions.trackSessions],
  /// the launch as a session.
  ///
  /// Needs the binding, which [Bugfree.init] makes sure of.
  void install() {
    if (!enabled || _installed) return;
    _installed = true;

    if (options.captureFlutterErrors) {
      _previousFlutterHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!details.silent) {
          // Nothing in the app caught it, but Flutter did: the widget shows an
          // error box and the app runs on, so the session is errored, not crashed.
          unawaited(_capture(
            details.exception,
            stackTrace: details.stack,
            handled: false,
            crashes: false,
            extra: {
              if (details.library != null) 'flutter_library': details.library,
              if (details.context != null) 'flutter_context': details.context!.toDescription(),
            },
          ));
        }
        final previous = _previousFlutterHandler;
        if (previous != null) {
          previous(details);
        } else {
          FlutterError.presentError(details);
        }
      };
    }

    if (options.capturePlatformErrors) {
      final dispatcher = ui.PlatformDispatcher.instance;
      _previousPlatformHandler = dispatcher.onError;
      dispatcher.onError = (error, stack) {
        unawaited(captureException(error, stackTrace: stack, level: BugfreeLevel.fatal, handled: false));
        // The engine's own handling (printing the error) stays as it was.
        return _previousPlatformHandler?.call(error, stack) ?? false;
      };
    }

    if (options.debugPrintBreadcrumbs) {
      _previousDebugPrint = debugPrint;
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && !message.startsWith('[bugfree]')) {
          addBreadcrumb(BugfreeBreadcrumb(category: 'console', message: message, level: 'debug'));
        }
        previous(message, wrapWidth: wrapWidth);
      };
    }

    WidgetsBinding.instance.addObserver(this);
    _startSession();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    addBreadcrumb(BugfreeBreadcrumb(category: 'app.lifecycle', message: state.name));
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= DateTime.now();
        // The system may end the app from here on without a word.
        unawaited(flush());
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since != null && DateTime.now().difference(since) >= options.sessionTimeout) {
          _session = null;
          _startSession();
        }
        _transport?.retryDeferred();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Reports an error; completes with the event's id once the server took it, or
  /// null when it was not sent: disabled, ignored, a repeat, sampled out, dropped
  /// by `beforeSend`, refused by the server, paused by a 429, or kept for later
  /// because the device is offline.
  ///
  /// [lastEventId] changes only for an event that passed sampling and
  /// `beforeSend`, so the reference shown to the user names an event that exists.
  /// An unhandled error ([handled] false) crashes the session.
  ///
  /// Without a [stackTrace], the error's own ([Error.stackTrace]) is used, and
  /// failing that the place of this call.
  Future<String?> captureException(
    Object error, {
    StackTrace? stackTrace,
    BugfreeLevel level = BugfreeLevel.error,
    String? type,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    String? fingerprint,
    bool handled = true,
  }) =>
      _capture(
        error,
        stackTrace: stackTrace,
        level: level,
        type: type,
        tags: tags,
        extra: extra,
        fingerprint: fingerprint,
        handled: handled,
        crashes: !handled,
      );

  Future<String?> _capture(
    Object error, {
    StackTrace? stackTrace,
    BugfreeLevel level = BugfreeLevel.error,
    String? type,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    String? fingerprint,
    required bool handled,
    required bool crashes,
  }) {
    if (!enabled) return Future.value(null);
    try {
      final event = _exceptionEvent(error, stackTrace, level, type, tags, extra, fingerprint, handled, crashes);
      if (event == null) return Future.value(null);
      return _dispatch(event);
    } catch (failure) {
      // The reporter's own failure must not reach the app.
      _log('error could not be captured: $failure');
      return Future.value(null);
    }
  }

  /// Records a free-form message; completes like [captureException].
  Future<String?> captureMessage(
    String message, {
    BugfreeLevel level = BugfreeLevel.info,
    String type = 'Message',
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    String? fingerprint,
  }) {
    if (!enabled) return Future.value(null);
    if (_matchesAny('$type: $message', options.ignoreErrors)) return Future.value(null);
    final event = _baseEvent(level, type, message, tags, extra)..fingerprint = fingerprint;
    return _dispatch(event);
  }

  BugfreeEvent? _exceptionEvent(
    Object error,
    StackTrace? stackTrace,
    BugfreeLevel level,
    String? type,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    String? fingerprint,
    bool handled,
    bool crashes,
  ) {
    final errorType = type ?? errorTypeOf(error);
    final message = errorMessageOf(error, errorType);
    if (_matchesAny('$errorType: $message', options.ignoreErrors)) return null;

    final trace = stackTrace ?? (error is Error ? error.stackTrace : null) ?? StackTrace.current;
    final parsed = parseStackTrace(trace, inAppPackages: _inAppPackages);
    final frames = parsed.frames;

    _noteSession(crashes ? 'crashed' : 'errored');

    final top = frames.isEmpty ? null : frames.first;
    if (_isDuplicate('$errorType|$message|${top?.file ?? ''}:${top?.line ?? 0}')) return null;

    final event = _baseEvent(level, errorType, message, tags, extra)
      ..stacktrace = frames
      ..fingerprint = fingerprint;
    if (!handled) event.extra['handled'] = false;
    if (!parsed.symbolic) {
      // Only the build's symbols can turn these addresses into code:
      // flutter symbolize -i <file> -d <debug-info>/app.android-arm64.symbols
      event.tags['symbolicated'] = 'false';
      event.extra['native_stacktrace'] = _clip(trace.toString(), 16000);
    }
    final culprit = frames.where((frame) => frame.inApp).firstOrNull ?? top;
    if (culprit != null) event.culprit = '${culprit.function} (${culprit.path ?? culprit.file}:${culprit.line})';
    return event;
  }

  BugfreeEvent _baseEvent(
    BugfreeLevel level,
    String type,
    String message,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
  ) {
    final details = _deviceDetails();
    return BugfreeEvent(
      eventId: newEventId(),
      level: level,
      type: type,
      message: _clip(message, 8000),
      environment: options.environment,
      release: options.release,
      runtime: details['dart_version'] == null ? 'Flutter' : 'Dart/${_majorMinor(details['dart_version']!)}',
      os: _osName(details['os'] ?? ''),
      user: _user,
      breadcrumbs: _breadcrumbs.list(),
      tags: {
        'sdk': 'bugfree-flutter/$sdkVersion',
        'build_mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
        if (options.commit.isNotEmpty) 'commit': _shortCommit(options.commit),
        ..._tags,
        ...?tags,
      },
      extra: {'device': details, ..._extra, ...?extra},
    );
  }

  /// Samples the event and runs `beforeSend`, then queues what is left.
  Future<String?> _dispatch(BugfreeEvent event) {
    final payload = _prepare(event);
    if (payload == null) return Future.value(null);
    // Still synchronous: lastEventId has the id as soon as the call returns, and
    // only for an event that is really on its way.
    _lastEventId = payload.eventId;
    return _track(_deliver(payload));
  }

  BugfreeEvent? _prepare(BugfreeEvent event) {
    if (_transport == null) return null;
    if (options.sampleRate < 1 && Random().nextDouble() >= options.sampleRate) return null;
    final beforeSend = options.beforeSend;
    if (beforeSend == null) return event;
    try {
      return beforeSend(event);
    } catch (failure) {
      _log('beforeSend failed, event dropped: $failure');
      return null;
    }
  }

  /// Completes with the id once the server took the event, or null when the
  /// transport dropped it, the server refused it or it waits for the network.
  Future<String?> _deliver(BugfreeEvent payload) async {
    final transport = _transport;
    if (transport == null) return null;
    final answer = await transport.send(payload.toJson());
    return answer == null ? null : payload.eventId;
  }

  Future<String?> _track(Future<String?> future) {
    final done = future.then<void>((_) {}, onError: (_) {});
    _inProgress.add(done);
    unawaited(done.whenComplete(() => _inProgress.remove(done)));
    return future;
  }

  /// Stops the same error from being sent over and over in a loop.
  bool _isDuplicate(String signature) {
    final now = DateTime.now();
    final previous = _seen[signature];
    _seen[signature] = now;
    if (_seen.length > 200) {
      _seen.removeWhere((_, at) => now.difference(at) > options.dedupeWindow);
    }
    return previous != null && now.difference(previous) < options.dedupeWindow;
  }

  /// Describes the device at the time of the event: what makes a layout bug or a
  /// failed request readable ("only on small screens", "only in dark mode").
  Map<String, String> _deviceDetails() {
    final details = <String, String>{...platformDetails()};
    try {
      final dispatcher = ui.PlatformDispatcher.instance;
      final view = dispatcher.implicitView ?? (dispatcher.views.isEmpty ? null : dispatcher.views.first);
      if (view != null && view.devicePixelRatio > 0) {
        final size = view.physicalSize / view.devicePixelRatio;
        details['screen'] = '${size.width.round()}x${size.height.round()}';
        details['pixel_ratio'] = view.devicePixelRatio.toStringAsFixed(2);
        details['orientation'] = size.width > size.height ? 'landscape' : 'portrait';
      }
      details['locale'] = dispatcher.locale.toLanguageTag();
      details['brightness'] = dispatcher.platformBrightness.name;
      details['text_scale'] = dispatcher.textScaleFactor.toStringAsFixed(2);
    } catch (_) {
      // Without a binding (a plain Dart test) there is no screen to describe.
    }
    return details;
  }

  /// Adds a step to what the next event shows happened before it.
  void addBreadcrumb(BugfreeBreadcrumb crumb) {
    if (!enabled) return;
    _breadcrumbs.add(crumb);
  }

  /// Sets who is using the app; null after signing out.
  void setUser(BugfreeUser? user) {
    _user = user;
    // The session's user is counted once, when an id first becomes known.
    final session = _session;
    if (session != null && !session.userCounted && (user?.id ?? '').isNotEmpty) {
      session.userCounted = true;
      _reportSession(const {});
    }
  }

  /// A tag every later event carries; null removes it.
  void setTag(String key, Object? value) {
    if (value == null) {
      _tags.remove(key);
    } else {
      _tags[key] = value;
    }
  }

  /// A value every later event carries under `extra`; null removes it.
  void setExtra(String key, Object? value) {
    if (value == null) {
      _extra.remove(key);
    } else {
      _extra[key] = value;
    }
  }

  /// Sends what a user wrote about a problem; true when the server stored it.
  /// Without an [eventId] it is tied to the latest captured event.
  Future<bool> captureFeedback({
    required String message,
    String name = '',
    String email = '',
    String? eventId,
    String url = '',
  }) async {
    final dsn = _dsn;
    final client = _http;
    if (!enabled || dsn == null || client == null || message.trim().isEmpty) return false;
    try {
      final response = await client
          .post(
            dsn.feedbackUrl,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'event_id': eventId ?? _lastEventId,
              'message': message,
              'name': name,
              'email': email,
              'url': url,
              'environment': options.environment,
              'release': options.release,
            }),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (failure) {
      _log('feedback could not be sent: $failure');
      return false;
    }
  }

  void _startSession() {
    if (!options.trackSessions || options.release.isEmpty || _session != null || !enabled) return;
    _session = _Session(DateTime.now().toUtc().toIso8601String(), userCounted: (_user?.id ?? '').isNotEmpty);
    _reportSession(const {'total': 1});
  }

  /// Marks the session: an unhandled error crashes it, a captured one errors it.
  /// Each change is reported once; a crashed session is errored too.
  void _noteSession(String outcome) {
    final session = _session;
    if (session == null || session.crashed) return;
    if (outcome == 'crashed') {
      _reportSession({'crashed': 1, 'errored': session.errored ? 0 : 1});
      session.crashed = true;
      session.errored = true;
      return;
    }
    if (session.errored) return;
    session.errored = true;
    _reportSession(const {'errored': 1});
  }

  void _reportSession(Map<String, int> counts) {
    final session = _session;
    final dsn = _dsn;
    final client = _http;
    final transport = _transport;
    if (session == null || dsn == null || client == null || transport == null || transport.paused) return;
    final body = jsonEncode({
      'sessions': [
        {
          'release': options.release,
          'environment': options.environment,
          'started': session.started,
          'did': _user?.id ?? '',
          'total': 0,
          'errored': 0,
          'crashed': 0,
          ...counts,
        },
      ],
    });
    final request = client
        .post(dsn.sessionsUrl, headers: const {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 10))
        .then<void>((_) {}, onError: (Object failure) => _log('session could not be reported: $failure'));
    _inProgress.add(request);
    unawaited(request.whenComplete(() => _inProgress.remove(request)));
  }

  /// Sends everything pending, waiting at most [timeout]; true when nothing is left.
  Future<bool> flush([Duration timeout = const Duration(seconds: 2)]) async {
    final deadline = DateTime.now().add(timeout);
    while (_inProgress.isNotEmpty && DateTime.now().isBefore(deadline)) {
      await Future.any([
        Future.wait(List.of(_inProgress)),
        Future<void>.delayed(deadline.difference(DateTime.now())),
      ]);
    }
    final transport = _transport;
    if (transport == null) return true;
    final left = deadline.difference(DateTime.now());
    return transport.flush(left.isNegative ? Duration.zero : left);
  }

  /// Puts back the handlers [install] replaced, at once. What was already
  /// captured is still sent; [close] waits for it.
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (options.captureFlutterErrors) FlutterError.onError = _previousFlutterHandler;
    if (options.capturePlatformErrors) ui.PlatformDispatcher.instance.onError = _previousPlatformHandler;
    if (options.debugPrintBreadcrumbs && _previousDebugPrint != null) debugPrint = _previousDebugPrint!;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Puts back the handlers [install] replaced, sends what is pending, waiting
  /// at most [timeout], and stops sending. A request still running after the
  /// timeout is cut off with the HTTP client.
  Future<void> close([Duration timeout = const Duration(seconds: 2)]) async {
    if (_closed) return;
    uninstall();
    await flush(timeout);
    _closed = true;
    if (_ownsHttp) _http?.close();
  }
}

class _Session {
  _Session(this.started, {required this.userCounted});

  final String started;
  bool userCounted;
  bool errored = false;
  bool crashed = false;
}

/// The type an issue is named after: the error's class, without the leading
/// underscore of a private one (`_Exception` is shown as `Exception`).
String errorTypeOf(Object error) {
  if (error is FlutterError) return 'FlutterError';
  final name = error.runtimeType.toString();
  return name.startsWith('_') ? name.substring(1) : name;
}

/// The error's message, without the type its text starts with
/// ("FormatException: bad input" is "bad input").
String errorMessageOf(Object error, String type) {
  final text = error is FlutterError ? error.message : error.toString();
  for (final prefix in ['$type: ', '_$type: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}

bool _matchesAny(String text, List<Pattern> patterns) {
  for (final pattern in patterns) {
    if (pattern is RegExp) {
      if (pattern.hasMatch(text)) return true;
    } else if (pattern is String && pattern.isNotEmpty && text.contains(pattern)) {
      return true;
    }
  }
  return false;
}

String _clip(String text, int max) => text.length > max ? '${text.substring(0, max)}…' : text;

String _majorMinor(String version) => version.split('.').take(2).join('.');

String _shortCommit(String commit) => commit.length > 12 ? commit.substring(0, 12) : commit;

const _osNames = {
  'android': 'Android',
  'ios': 'iOS',
  'macos': 'macOS',
  'windows': 'Windows',
  'linux': 'Linux',
  'fuchsia': 'Fuchsia',
  'web': 'Web',
};

String _osName(String os) => _osNames[os] ?? os;

final Random _random = () {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}();

/// A random (version 4) UUID.
String newEventId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
