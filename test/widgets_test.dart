import 'dart:convert';

import 'package:bugfree_flutter/bugfree_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _dsn = 'http://key@localhost:3000/ingest';

void main() {
  late List<http.Request> requests;
  late BugfreeClient client;

  setUp(() {
    requests = [];
    client = BugfreeClient(BugfreeOptions(
      dsn: _dsn,
      trackSessions: false,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    ));
  });

  List<dynamic> breadcrumbsOfNextEvent() {
    final event = requests.lastWhere((request) => request.url.path.endsWith('/store'));
    return (jsonDecode(event.body) as Map<String, dynamic>)['breadcrumbs'] as List? ?? [];
  }

  testWidgets('the navigator observer records route changes and tags the route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [BugfreeNavigatorObserver(client: client)],
      routes: {
        '/': (_) => const Text('home'),
        '/cart': (_) => const Text('cart'),
      },
    ));

    navigator.currentState!.pushNamed('/cart');
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await client.captureMessage('after navigating');
      await client.flush();
    });

    final messages = breadcrumbsOfNextEvent().map((crumb) => crumb['message']).toList();
    expect(messages, containsAllInOrder(['(none) → /', '/ → /cart', '/cart → /']));
    final event = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(event['tags'], containsPair('route', '/'));
  });

  testWidgets('an unnamed route clears the route tag', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [BugfreeNavigatorObserver(client: client)],
      routes: {'/': (_) => const Text('home'), '/cart': (_) => const Text('cart')},
    ));

    navigator.currentState!.pushNamed('/cart');
    await tester.pumpAndSettle();
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('details')));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await client.captureMessage('on the unnamed page');
      await client.flush();
    });

    final event = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect((event['tags'] as Map).containsKey('route'), isFalse);
    expect(breadcrumbsOfNextEvent().last['message'], '/cart → MaterialPageRoute');
  });

  test('the HTTP client records requests without their query string', () async {
    final api = BugfreeHttpClient(
      MockClient((request) async => http.Response('nope', request.url.path == '/missing' ? 404 : 200)),
      client: client,
    );

    await api.get(Uri.parse('https://api.example.com/orders?token=secret'));
    await api.get(Uri.parse('https://api.example.com/missing'));
    await client.captureMessage('after requests');
    await client.flush();

    final crumbs = breadcrumbsOfNextEvent();
    expect(crumbs[0]['message'], 'GET https://api.example.com/orders → 200');
    expect(crumbs[0]['level'], 'info');
    expect(crumbs[1]['message'], 'GET https://api.example.com/missing → 404');
    expect(crumbs[1]['level'], 'warning');
    expect(jsonEncode(crumbs), isNot(contains('secret')));
  });

  test('the HTTP client records a failed request and rethrows', () async {
    final api = BugfreeHttpClient(
      MockClient((request) async => throw http.ClientException('connection refused')),
      client: client,
    );

    await expectLater(api.get(Uri.parse('https://api.example.com/orders')), throwsA(isA<http.ClientException>()));
    await client.captureMessage('after the failure');
    await client.flush();

    final crumb = breadcrumbsOfNextEvent().single;
    expect(crumb['message'], 'GET https://api.example.com/orders failed: ClientException');
    expect(crumb['level'], 'error');
  });

  testWidgets('the feedback dialog sends what the user wrote, tied to the latest event', (tester) async {
    client.setUser(const BugfreeUser(id: '7', email: 'ada@example.com', name: 'Ada'));
    String? eventId;
    await tester.runAsync(() async {
      eventId = await client.captureMessage('checkout failed');
      await client.flush();
    });

    bool? sent;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => sent = await showBugfreeFeedbackDialog(context, client: client),
          child: const Text('report'),
        ),
      ),
    ));
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();

    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    // Nothing written yet: the send button waits.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('bugfree-feedback-message')), 'The pay button did nothing');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Send'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(sent, isTrue);
    expect(find.text('Report a problem'), findsNothing);
    final feedback = requests.lastWhere((request) => request.url.path.endsWith('/feedback'));
    final body = jsonDecode(feedback.body) as Map<String, dynamic>;
    expect(body['event_id'], eventId);
    expect(body['message'], 'The pay button did nothing');
    expect(body['name'], 'Ada');
  });

  testWidgets('the feedback dialog translates through its labels and can be closed', (tester) async {
    bool? sent;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => sent = await showBugfreeFeedbackDialog(
            context,
            client: client,
            labels: const BugfreeFeedbackLabels(title: 'Something broke', cancel: 'Close'),
          ),
          child: const Text('report'),
        ),
      ),
    ));
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();

    expect(find.text('Something broke'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(sent, isFalse);
    expect(requests.where((request) => request.url.path.endsWith('/feedback')), isEmpty);
  });

  testWidgets('a disabled client opens no dialog', (tester) async {
    bool? sent;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => sent = await showBugfreeFeedbackDialog(context, client: BugfreeClient.disabled()),
          child: const Text('report'),
        ),
      ),
    ));
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();

    expect(sent, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
