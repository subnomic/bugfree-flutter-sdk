import 'package:bugfree_flutter/bugfree_flutter.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// flutter run --dart-define=BUGFREE_DSN=http://<key>@10.0.2.2:3000/ingest
Future<void> main() async {
  await Bugfree.init(const BugfreeOptions(
    dsn: String.fromEnvironment('BUGFREE_DSN'),
    environment: 'development',
    release: 'bugfree-example@1.0.0+1',
    debug: true,
  ));
  runApp(const ExampleApp());
}

// Requests made through this client become breadcrumbs.
final api = BugfreeHttpClient(http.Client());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bugfree example',
      navigatorObservers: [BugfreeNavigatorObserver()],
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _checkout(BuildContext context) async {
    try {
      await api.get(Uri.parse('https://example.com/checkout'));
      throw StateError('the cart is empty');
    } catch (error, stackTrace) {
      await Bugfree.captureException(error, stackTrace: stackTrace, tags: {'step': 'checkout'});
      if (context.mounted) await showBugfreeFeedbackDialog(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('bugfree example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => _checkout(context),
              child: const Text('Report a caught error'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              // Nothing catches this one: Bugfree.init reports it.
              onPressed: () => throw UnsupportedError('an uncaught error'),
              child: const Text('Throw an uncaught error'),
            ),
          ],
        ),
      ),
    );
  }
}
