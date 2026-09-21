import 'dart:convert';

import 'package:bugfree_flutter/bugfree_flutter.dart';
import 'package:bugfree_flutter/src/client.dart' show errorMessageOf, errorTypeOf, newEventId;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _dsn = 'http://key@localhost:3000/ingest';

/// A client whose requests land in [requests] instead of the network.
class _Recorder {
  _Recorder({int status = 200}) {
    client = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', status);
    });
  }

  final requests = <http.Request>[];
  late final MockClient client;

  List<Map<String, dynamic>> bodies(String endpoint) => [
        for (final request in requests)
          if (request.url.path.endsWith('/$endpoint')) jsonDecode(request.body) as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> get events => bodies('store');
}

BugfreeClient _client(_Recorder recorder, [BugfreeOptions? options]) {
  final base = options ?? const BugfreeOptions();
  return BugfreeClient(
    BugfreeOptions(
      dsn: _dsn,
      environment: base.environment,
      release: base.release,
      commit: base.commit,
      sampleRate: base.sampleRate,
      ignoreErrors: base.ignoreErrors,
      trackSessions: base.trackSessions,
      beforeSend: base.beforeSend,
      captureFlutterErrors: base.captureFlutterErrors,
      capturePlatformErrors: base.capturePlatformErrors,
      debugPrintBreadcrumbs: base.debugPrintBreadcrumbs,
      httpClient: recorder.client,
    ),
  );
}

void _throwState() => throw StateError('cart is empty');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a client without a DSN sends nothing', () async {
    final client = BugfreeClient(const BugfreeOptions());

    expect(client.enabled, isFalse);
    expect(await client.captureException(StateError('x')), isNull);
    expect(await client.captureMessage('x'), isNull);
    expect(await client.captureFeedback(message: 'x'), isFalse);
    expect(await client.flush(), isTrue);
  });

  test('sends an exception with its frames, context and the SDK tag', () async {
    final recorder = _Recorder();
    final client = _client(
        recorder, const BugfreeOptions(environment: 'staging', release: 'shop@1.0.0', commit: '0123456789abcdef0123'));
    client.setUser(const BugfreeUser(id: '42', email: 'ada@example.com'));
    client.setTag('plan', 'team');
    client.addBreadcrumb(BugfreeBreadcrumb(category: 'ui', message: 'tapped pay'));

    Object? error;
    StackTrace? stack;
    try {
      _throwState();
    } catch (caught, trace) {
      error = caught;
      stack = trace;
    }
    final id = await client.captureException(error!, stackTrace: stack, tags: {'step': 'checkout'});
    await client.flush();

    final event = recorder.events.single;
    expect(event['event_id'], id);
    expect(client.lastEventId, id);
    expect(event['platform'], 'flutter');
    expect(event['level'], 'error');
    expect(event['type'], 'StateError');
    expect(event['message'], 'Bad state: cart is empty');
    expect(event['environment'], 'staging');
    expect(event['release'], 'shop@1.0.0');
    expect(event['runtime'], startsWith('Dart/'));
    expect(event['user'], {'id': '42', 'email': 'ada@example.com'});
    expect(event['tags'], containsPair('sdk', 'bugfree-flutter/$sdkVersion'));
    expect(event['tags'], containsPair('plan', 'team'));
    expect(event['tags'], containsPair('step', 'checkout'));
    expect(event['tags'], containsPair('commit', '0123456789ab'));
    expect((event['extra'] as Map)['device'], isA<Map>());
    expect((event['breadcrumbs'] as List).single['message'], 'tapped pay');

    final frames = (event['stacktrace'] as List).cast<Map<String, dynamic>>();
    expect(frames.first['function'], '_throwState');
    expect(frames.first['in_app'], isTrue);
    expect(frames.first['path'], 'test/client_test.dart');
    expect(event['culprit'], startsWith('_throwState (test/client_test.dart:'));
  });

  test('uses the stack trace an Error carries', () async {
    final recorder = _Recorder();
    final client = _client(recorder);

    try {
      _throwState();
    } on StateError catch (error) {
      await client.captureException(error);
    }
    await client.flush();

    final frames = recorder.events.single['stacktrace'] as List;
    expect(frames.first['function'], '_throwState');
  });

  test('sends a message', () async {
    final recorder = _Recorder();
    final client = _client(recorder);

    await client.captureMessage('coupon service slow', level: BugfreeLevel.warning);
    await client.flush();

    final event = recorder.events.single;
    expect(event['type'], 'Message');
    expect(event['level'], 'warning');
    expect(event['message'], 'coupon service slow');
  });

  test('sends the same error once inside the dedupe window', () async {
    final recorder = _Recorder();
    final client = _client(recorder);
    final stack = StackTrace.current;

    await client.captureException(StateError('loop'), stackTrace: stack);
    expect(await client.captureException(StateError('loop'), stackTrace: stack), isNull);
    await client.flush();

    expect(recorder.events, hasLength(1));
  });

  test('ignoreErrors drops matching errors', () async {
    final recorder = _Recorder();
    final client = _client(recorder, BugfreeOptions(ignoreErrors: ['SocketException', RegExp(r'^Timeout')]));

    expect(await client.captureException(const FormatException('SocketException: gone')), isNull);
    expect(await client.captureMessage('late'), isNotNull);
    await client.flush();

    expect(recorder.events, hasLength(1));
  });

  test('beforeSend edits or drops an event', () async {
    final recorder = _Recorder();
    final client = _client(
      recorder,
      BugfreeOptions(beforeSend: (event) {
        if (event.message.contains('drop me')) return null;
        event.user = null;
        event.tags['scrubbed'] = true;
        return event;
      }),
    );
    client.setUser(const BugfreeUser(email: 'ada@example.com'));

    expect(await client.captureMessage('drop me'), isNull);
    await client.captureMessage('keep me');
    await client.flush();

    final event = recorder.events.single;
    expect(event.containsKey('user'), isFalse);
    expect(event['tags'], containsPair('scrubbed', true));
  });

  test('a beforeSend that throws drops the event without reaching the app', () async {
    final recorder = _Recorder();
    final client = _client(recorder, BugfreeOptions(beforeSend: (event) => throw StateError('bug in the hook')));

    expect(await client.captureMessage('x'), isNull);
    expect(recorder.events, isEmpty);
  });

  test('sampleRate 0 sends nothing', () async {
    final recorder = _Recorder();
    final client = _client(recorder, const BugfreeOptions(sampleRate: 0));

    expect(await client.captureMessage('x'), isNull);
    await client.flush();
    expect(recorder.events, isEmpty);
  });

  test('lastEventId only names events that passed sampling and beforeSend', () async {
    final sampled = _client(_Recorder(), const BugfreeOptions(sampleRate: 0));
    await sampled.captureMessage('sampled out');
    expect(sampled.lastEventId, isNull);

    final recorder = _Recorder();
    final client = _client(
      recorder,
      BugfreeOptions(beforeSend: (event) => event.message.contains('drop me') ? null : event),
    );
    final kept = await client.captureMessage('keep me');
    await client.captureMessage('drop me');
    await client.captureException(StateError('drop me'), stackTrace: StackTrace.current);

    expect(client.lastEventId, kept);
    expect(await client.captureFeedback(message: 'it broke'), isTrue);
    expect(recorder.bodies('feedback').single['event_id'], kept);
  });

  test('a capture the server refuses completes with null', () async {
    final client = _client(_Recorder(status: 401));

    final future = client.captureMessage('refused');
    final id = client.lastEventId;

    expect(id, isNotNull);
    expect(await future, isNull);
  });

  test('a capture paused by a 429 completes with null', () async {
    final client = _client(_Recorder(status: 429));

    expect(await client.captureMessage('first'), isNull);
    expect(await client.captureMessage('second'), isNull);
  });

  test('sends feedback tied to the latest event', () async {
    final recorder = _Recorder();
    final client = _client(recorder);

    final id = await client.captureMessage('checkout failed');
    expect(await client.captureFeedback(message: 'The pay button did nothing', email: 'ada@example.com'), isTrue);

    final feedback = recorder.bodies('feedback').single;
    expect(feedback['event_id'], id);
    expect(feedback['message'], 'The pay button did nothing');
    expect(feedback['email'], 'ada@example.com');
  });

  group('sessions', () {
    test('a launch counts once, an error errors it and an unhandled one crashes it', () async {
      final recorder = _Recorder();
      final client = _client(recorder, const BugfreeOptions(release: 'shop@1.0.0', debugPrintBreadcrumbs: false));
      client.install();

      await client.captureMessage('noted');
      await client.captureException(StateError('handled'), stackTrace: StackTrace.current);
      await client.captureException(StateError('unhandled'), stackTrace: StackTrace.current, handled: false);
      await client.captureException(StateError('again'), stackTrace: StackTrace.current, handled: false);
      await client.close();

      final sessions = recorder.bodies('sessions').map((body) => (body['sessions'] as List).single as Map).toList();
      expect(sessions.map((session) => [session['total'], session['errored'], session['crashed']]), [
        [1, 0, 0],
        [0, 1, 0],
        [0, 0, 1],
      ]);
      expect(sessions.every((session) => session['release'] == 'shop@1.0.0'), isTrue);
    });

    test('an error Flutter caught errors the session without crashing it', () async {
      final recorder = _Recorder();
      final previous = FlutterError.onError;
      FlutterError.onError = (_) {};
      final client = _client(
        recorder,
        const BugfreeOptions(release: 'shop@1.0.0', capturePlatformErrors: false, debugPrintBreadcrumbs: false),
      );
      client.install();

      FlutterError.onError!(FlutterErrorDetails(exception: FlutterError('build failed'), stack: StackTrace.current));
      await client.close();
      FlutterError.onError = previous;

      final sessions = recorder.bodies('sessions').map((body) => (body['sessions'] as List).single as Map).toList();
      expect(sessions.map((session) => [session['total'], session['errored'], session['crashed']]), [
        [1, 0, 0],
        [0, 1, 0],
      ]);
      expect(recorder.events.single['extra'], containsPair('handled', false));
    });

    test('no session without a release', () async {
      final recorder = _Recorder();
      final client = _client(recorder, const BugfreeOptions(debugPrintBreadcrumbs: false));
      client.install();
      await client.close();

      expect(recorder.bodies('sessions'), isEmpty);
    });
  });

  test('install reports what FlutterError.onError receives and keeps the previous handler', () async {
    final recorder = _Recorder();
    final previous = FlutterError.onError;
    final forwarded = <FlutterErrorDetails>[];
    FlutterError.onError = forwarded.add;
    final client = _client(recorder,
        const BugfreeOptions(trackSessions: false, capturePlatformErrors: false, debugPrintBreadcrumbs: false));
    client.install();

    final details = FlutterErrorDetails(
      exception: FlutterError('A RenderFlex overflowed by 42 pixels on the right.'),
      stack: StackTrace.current,
      library: 'rendering library',
      context: ErrorDescription('during layout'),
    );
    FlutterError.onError!(details);
    await client.close();
    FlutterError.onError = previous;

    expect(forwarded, [details]);
    final event = recorder.events.single;
    expect(event['type'], 'FlutterError');
    expect(event['message'], 'A RenderFlex overflowed by 42 pixels on the right.');
    expect(event['extra'], containsPair('flutter_library', 'rendering library'));
    expect(event['extra'], containsPair('flutter_context', 'during layout'));
    expect(event['extra'], containsPair('handled', false));
  });

  test('close puts the replaced handlers back', () async {
    final recorder = _Recorder();
    final previous = FlutterError.onError;
    final client = _client(recorder, const BugfreeOptions(trackSessions: false, debugPrintBreadcrumbs: false));

    client.install();
    expect(FlutterError.onError, isNot(same(previous)));
    await client.close();

    expect(FlutterError.onError, same(previous));
    expect(client.enabled, isFalse);
  });

  test('debugPrint output becomes a breadcrumb', () async {
    final recorder = _Recorder();
    final client = _client(recorder,
        const BugfreeOptions(trackSessions: false, captureFlutterErrors: false, capturePlatformErrors: false));
    client.install();

    debugPrint('cart restored with 3 items');
    await client.captureMessage('then this');
    await client.close();

    final crumbs = recorder.events.single['breadcrumbs'] as List;
    expect(crumbs.any((crumb) => crumb['category'] == 'console' && crumb['message'] == 'cart restored with 3 items'),
        isTrue);
  });

  test('lifecycle changes become breadcrumbs', () async {
    final recorder = _Recorder();
    final client = _client(recorder, const BugfreeOptions(trackSessions: false));

    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    client.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await client.captureMessage('back');
    await client.flush();

    final crumbs = (recorder.events.single['breadcrumbs'] as List).map((crumb) => crumb['message']);
    expect(crumbs, ['paused', 'resumed']);
  });

  test('a second Bugfree.init still sends what the first client queued', () async {
    final original = FlutterError.onError;
    final first = <String>[];
    final second = <String>[];
    MockClient slow(List<String> into) => MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (request.url.path.endsWith('/store')) into.add(jsonDecode(request.body)['message'] as String);
          return http.Response('{}', 200);
        });

    await Bugfree.init(BugfreeOptions(dsn: _dsn, trackSessions: false, httpClient: slow(first)));
    final firstHandler = FlutterError.onError;
    final pending = Bugfree.captureMessage('queued before the second init');
    await Bugfree.init(BugfreeOptions(dsn: _dsn, trackSessions: false, httpClient: slow(second)));
    final secondHandler = FlutterError.onError;

    expect(await pending, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(first, ['queued before the second init']);
    // The first client's close puts nothing back over the second client's hooks.
    expect(secondHandler, isNot(same(firstHandler)));
    expect(FlutterError.onError, same(secondHandler));

    await Bugfree.captureMessage('after');
    await Bugfree.close();
    expect(second, ['after']);
    expect(FlutterError.onError, same(original));
  });

  group('error names', () {
    test('a private class loses its underscore', () {
      expect(errorTypeOf(Exception('x')), 'Exception');
      expect(errorMessageOf(Exception('payment declined'), 'Exception'), 'payment declined');
    });

    test('the type at the start of the message is dropped', () {
      expect(errorMessageOf(const FormatException('bad input'), 'FormatException'), 'bad input');
    });
  });

  test('event ids are version 4 UUIDs', () {
    expect(newEventId(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });
}
