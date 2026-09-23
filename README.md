# bugfree_flutter

The bugfree SDK for Flutter applications on Android, iOS, desktop and the web.
It reports the errors Flutter catches and the ones nothing caught, with the
device, the steps that led to them and release health.

```sh
flutter pub add bugfree_flutter
```

It needs Flutter 3.24 or later and depends on nothing beyond `http`.

## Setup

```dart
import 'package:bugfree_flutter/bugfree_flutter.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  await Bugfree.init(const BugfreeOptions(
    dsn: String.fromEnvironment('BUGFREE_DSN'), // http://<key>@host:3000/ingest
    environment: 'production',
    release: 'shop@2.3.0+41',
    commit: String.fromEnvironment('GIT_COMMIT'),
  ));
  runApp(const ShopApp());
}
```

```sh
flutter build apk --release \
  --dart-define=BUGFREE_DSN=https://<key>@bugfree.example.com/ingest \
  --dart-define=GIT_COMMIT=$(git rev-parse HEAD)
```

An empty `dsn` disables the SDK: nothing is hooked and every call is a no-op.
`Bugfree.init` initialises the Flutter binding itself, and the package whose
`main` calls it is taken as your code (set `inAppPackages` to name others).

From then on the SDK reports:

- errors Flutter catches while building, laying out and painting
  (`FlutterError.onError`); the previous handler still runs, so the red screen
  and the console output stay as they were
- errors nothing caught, from async code, timers and platform channels
  (`PlatformDispatcher.onError`), at the fatal level
- the app going to the background and coming back, and what `debugPrint`
  writes, as breadcrumbs
- the device under `extra.device`: operating system and version, screen size,
  pixel ratio, orientation, locale, brightness and text scale
- every launch as a session of the release, for release health: an error
  nothing caught crashes it, while a captured error or one Flutter caught while
  building (the widget shows an error box and the app runs on) marks it errored;
  coming back after `sessionTimeout` in the background starts a new one

### Navigation and HTTP breadcrumbs

```dart
MaterialApp(navigatorObservers: [BugfreeNavigatorObserver()])
GoRouter(observers: [BugfreeNavigatorObserver()], routes: [...])

final api = BugfreeHttpClient(http.Client()); // method, address, status, duration
```

The HTTP breadcrumbs leave out bodies, headers and the query string. A route is
named after its `RouteSettings.name`.

## Capturing

```dart
try {
  await checkout(cart);
} catch (error, stackTrace) {
  Bugfree.captureException(error, stackTrace: stackTrace, tags: {'step': 'checkout'});
}
Bugfree.captureMessage('cart recovered', level: BugfreeLevel.info);

Bugfree.setUser(BugfreeUser(id: user.id, email: user.email));
Bugfree.setTag('plan', 'team');
Bugfree.addBreadcrumb(BugfreeBreadcrumb(category: 'ui', message: 'tapped pay'));

await Bugfree.flush(); // before a checkpoint
```

Both capture calls return a `Future` of the event id once the server took the
event, and `null` when it was not sent: ignored, sampled out, dropped by
`beforeSend`, refused, paused by a `429`, or kept for later while offline.
`Bugfree.lastEventId` has the id as soon as the call returns, to show the user as
a reference; it only changes for an event that passed sampling and `beforeSend`.

### User feedback

```dart
// A Material dialog that asks what happened, tied to the latest captured event
await showBugfreeFeedbackDialog(context,
    labels: const BugfreeFeedbackLabels(title: 'Sorry, that did not work'));

// Or from a form of your own
await Bugfree.captureFeedback(message: message, email: email);
```

## Where the error happened

An app on a phone has no source files to read, so events carry no code. Every
frame of your package carries its path in the project (`lib/cart/checkout.dart`)
and its line; with an editor chosen in the bugfree account settings, the frame
opens at that line in your own checkout.

A build made with `--split-debug-info` or `--obfuscate` writes addresses instead
of names into its stack traces. Such an event has no frames: it carries the tag
`symbolicated: false` and the raw trace under `extra.native_stacktrace`, which
`flutter symbolize` turns back into code with that build's symbols.

## Delivery

Events go out one after another from a bounded queue. A `429` answer pauses
sending for as long as its `Retry-After` asks; a server error is retried once.
An event that could not be sent because the device was offline is kept in
memory, thirty at most, and sent once the network answers again or the app
returns to the foreground. The app going to the background flushes the queue.

## Options

| Option | Default | Meaning |
|---|---|---|
| `dsn` | `''` | Project key and server address. Empty turns the SDK off. |
| `environment` | `'production'` | Environment tag. |
| `release` | `''` | Release, for regressions and release health. |
| `commit` | `''` | The commit the app was built from; the issue page names it. |
| `sampleRate` | `1` | Share of events to send. |
| `maxBreadcrumbs` | `30` | Ring buffer size. |
| `dedupeWindow` | `10 s` | The same error is sent once per window. |
| `ignoreErrors` | `[]` | Strings or RegExps; drops errors whose `Type: message` matches. |
| `inAppPackages` | `[]` | Packages that are your code; empty, the caller of `init`. |
| `trackSessions` | `true` | Report every launch as a session of the release. |
| `sessionTimeout` | `30 s` | Time in the background after which a new session starts. |
| `captureFlutterErrors` | `true` | Report what `FlutterError.onError` receives. |
| `capturePlatformErrors` | `true` | Report what `PlatformDispatcher.onError` receives. |
| `debugPrintBreadcrumbs` | `true` | Record `debugPrint` output as breadcrumbs. |
| `maxQueueSize` | `100` | Events waiting at most; new ones beyond it are dropped. |
| `httpClient` | `null` | The client events are sent with. |
| `beforeSend` | `null` | Return `null` to drop, or edit the event. |
| `debug` | `false` | Write SDK problems to the console. |

## Tests

```sh
flutter test
```

In the tests of an app, `Bugfree.client = BugfreeClient.disabled()` keeps
everything quiet.

## Releasing

The SDK is published to `github.com/subnomic/bugfree-flutter-sdk`, with this
directory as that repository's root, and to pub.dev, by the bugfree release: one
release on the bugfree repository's Releases page with the tag `v0.9.6`
publishes the server and every SDK at that version. Raise `version` in
`pubspec.yaml`, `sdkVersion` in `lib/src/client.dart` and the section in
`CHANGELOG.md` with the others.

The release workflow checks that the versions match the tag, runs the analyzer
and the tests, pushes this directory to that repository as one commit and tags
it there as `v0.9.6`. The tag starts `.github/workflows/publish.yml` in that
repository, which publishes to pub.dev through GitHub's OIDC token, so no pub.dev
credentials are stored anywhere. Before the first release, publish the package
once by hand and turn on automated publishing on pub.dev for
`subnomic/bugfree-flutter-sdk` with the tag pattern `v{{version}}`. Since this
directory carries a workflow, the release's `SDK_PUSH_TOKEN` needs Workflows: Read
and write on that repository besides Contents; GitHub refuses the push otherwise.

## License

MIT, see [`LICENSE`](LICENSE).
