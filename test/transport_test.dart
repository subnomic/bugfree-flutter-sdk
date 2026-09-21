import 'dart:async';
import 'dart:convert';

import 'package:bugfree_flutter/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _url = Uri.parse('http://localhost:3000/ingest/v1/key/store');

Transport _transport(MockClient client, {int maxQueueSize = 100}) => Transport(
      _url,
      client: client,
      maxQueueSize: maxQueueSize,
      retryDelay: Duration.zero,
    );

void main() {
  test('posts the event as JSON and returns the answer', () async {
    late http.Request received;
    final transport = _transport(MockClient((request) async {
      received = request;
      return http.Response('{"short_id":"SHOP-1"}', 200);
    }));

    final result = await transport.send({'type': 'StateError'});

    expect(received.url, _url);
    expect(received.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(received.body), {'type': 'StateError'});
    expect(result, {'short_id': 'SHOP-1'});
  });

  test('pauses after a 429 for as long as Retry-After asks', () async {
    var calls = 0;
    final transport = _transport(MockClient((request) async {
      calls++;
      return http.Response('', 429, headers: {'retry-after': '120'});
    }));

    expect(await transport.send({'n': 1}), isNull);
    expect(transport.paused, isTrue);
    expect(await transport.send({'n': 2}), isNull);
    expect(calls, 1);
  });

  test('does not retry a client error', () async {
    var calls = 0;
    final transport = _transport(MockClient((request) async {
      calls++;
      return http.Response('invalid key', 401);
    }));

    expect(await transport.send({}), isNull);
    expect(calls, 1);
  });

  test('retries a server error once', () async {
    var calls = 0;
    final transport = _transport(MockClient((request) async {
      calls++;
      return calls == 1 ? http.Response('', 503) : http.Response('{}', 200);
    }));

    expect(await transport.send({}), isNotNull);
    expect(calls, 2);
  });

  test('keeps an event the network failed and sends it after the next one', () async {
    var online = false;
    final bodies = <String>[];
    final transport = _transport(MockClient((request) async {
      if (!online) throw http.ClientException('offline');
      bodies.add(request.body);
      return http.Response('{}', 200);
    }));

    expect(await transport.send({'n': 1}), isNull);
    expect(transport.deferred, 1);

    online = true;
    await transport.send({'n': 2});
    await transport.flush();

    expect(bodies.map(jsonDecode), [
      {'n': 2},
      {'n': 1},
    ]);
    expect(transport.deferred, 0);
  });

  test('drops new events once the queue is full', () async {
    final transport = _transport(
      MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      }),
      maxQueueSize: 1,
    );

    final first = transport.send({'n': 1});
    final second = transport.send({'n': 2});
    final third = transport.send({'n': 3});

    expect(await third, isNull);
    expect(await first, isNotNull);
    expect(await second, isNotNull);
  });

  test('flush waits for the queue', () async {
    final transport = _transport(MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return http.Response('{}', 200);
    }));

    unawaited(transport.send({}));
    expect(await transport.flush(const Duration(seconds: 1)), isTrue);
    expect(transport.pending, 0);
  });

  group('parseRetryAfter', () {
    final now = DateTime.utc(2026, 9, 21, 12);

    test('reads seconds', () {
      expect(parseRetryAfter('30'), const Duration(seconds: 30));
    });

    test('reads an HTTP date', () {
      expect(parseRetryAfter('Mon, 21 Sep 2026 12:02:00 GMT', now: now), const Duration(minutes: 2));
    });

    test('falls back to a minute', () {
      expect(parseRetryAfter(null), defaultRetryAfter);
      expect(parseRetryAfter('0'), defaultRetryAfter);
      expect(parseRetryAfter('soon'), defaultRetryAfter);
      expect(parseRetryAfter('Mon, 21 Sep 2026 11:00:00 GMT', now: now), defaultRetryAfter);
    });
  });
}
