import 'package:bugfree_flutter/src/dsn.dart';
import 'package:bugfree_flutter/src/stack_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseStackTrace', () {
    test('reads Dart VM frames and marks the app package as app code', () {
      final trace = StackTrace.fromString('''
#0      CartState.checkout (package:shop/src/cart.dart:42:7)
#1      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1170:21)
<asynchronous suspension>
#2      _rootRun (dart:async/zone.dart:1399:13)
#3      main.<anonymous closure> (package:shop/main.dart:12)
''');

      final frames = parseStackTrace(trace, inAppPackages: {'shop'}).frames;

      expect(frames, hasLength(4));
      expect(frames[0].function, 'CartState.checkout');
      expect(frames[0].file, 'package:shop/src/cart.dart');
      expect(frames[0].line, 42);
      expect(frames[0].column, 7);
      expect(frames[0].inApp, isTrue);
      expect(frames[0].path, 'lib/src/cart.dart');
      expect(frames[0].package, 'shop');

      expect(frames[1].inApp, isFalse);
      expect(frames[1].path, isNull);
      expect(frames[2].file, 'dart:async/zone.dart');
      expect(frames[2].inApp, isFalse);

      expect(frames[3].function, 'main.<fn>');
      expect(frames[3].line, 12);
      expect(frames[3].column, 0);
    });

    test('reads the terse format of a debug web build as the VM writes it', () {
      final trace = StackTrace.fromString('packages/shop/src/cart.dart 42:7  checkout\n'
          'dart-sdk/lib/async/zone.dart 1399:13  _rootRun');

      final frames = parseStackTrace(trace, inAppPackages: {'shop'}).frames;

      expect(frames.first.file, 'package:shop/src/cart.dart');
      expect(frames.first.line, 42);
      expect(frames.first.inApp, isTrue);
      expect(frames.first.function, 'checkout');
    });

    test('reads V8 and Firefox frames of a release web build', () {
      final v8 = parseStackTrace(StackTrace.fromString(
        '    at Object.checkout (https://shop.example.com/main.dart.js:1234:56)\n'
        '    at https://shop.example.com/main.dart.js:99:1',
      )).frames;
      expect(v8[0].function, 'Object.checkout');
      expect(v8[0].file, 'https://shop.example.com/main.dart.js');
      expect(v8[0].line, 1234);
      expect(v8[0].column, 56);
      expect(v8[1].function, '<anonymous>');
      expect(v8[1].line, 99);

      final gecko =
          parseStackTrace(StackTrace.fromString('checkout@https://shop.example.com/main.dart.js:10:20')).frames;
      expect(gecko.single.function, 'checkout');
      expect(gecko.single.line, 10);
    });

    test('drops the SDK frames above the caller', () {
      final trace = StackTrace.fromString('''
#0      BugfreeClient.captureException (package:bugfree_flutter/src/client.dart:10:5)
#1      Bugfree.captureException (package:bugfree_flutter/src/bugfree.dart:20:5)
#2      CartState.checkout (package:shop/cart.dart:42:7)
''');

      final frames = parseStackTrace(trace, inAppPackages: {'shop'}).frames;

      expect(frames.first.file, 'package:shop/cart.dart');
    });

    test('recognises a trace without symbols', () {
      final trace = StackTrace.fromString('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 12345, tid: 12367, name 1.ui
build_id: '0123456789abcdef'
isolate_dso_base: 7a1b2c3000, vm_dso_base: 7a1b2c3000
    #00 abs 0000007a1b3d4e5f virt 0000000000211e5f _kDartIsolateSnapshotInstructions+0x1a2b3f
''');

      final parsed = parseStackTrace(trace);

      expect(parsed.symbolic, isFalse);
      expect(parsed.frames, isEmpty);
    });

    test('caps the number of frames', () {
      final lines = List.generate(80, (index) => '#$index      f$index (package:shop/a.dart:${index + 1}:1)');
      final frames = parseStackTrace(StackTrace.fromString(lines.join('\n'))).frames;

      expect(frames, hasLength(maxFrames));
    });

    test('takes a file path outside the pub cache for app code', () {
      final frames = parseStackTrace(StackTrace.fromString('''
#0      main (file:///Users/dev/shop/test/cart_test.dart:8:3)
#1      Declarer.test (file:///Users/dev/.pub-cache/hosted/pub.dev/test_api-0.7.0/lib/src/backend/declarer.dart:1:1)
''')).frames;

      expect(frames[0].inApp, isTrue);
      expect(frames[0].path, 'test/cart_test.dart');
      expect(frames[1].inApp, isFalse);
    });
  });

  test('finds the application package from the caller of init', () {
    final trace = StackTrace.fromString('''
#0      Bugfree.init (package:bugfree_flutter/src/bugfree.dart:30:5)
#1      main (package:shop/main.dart:8:17)
''');

    expect(callerPackage(trace), 'shop');
  });

  group('Dsn.parse', () {
    test('builds the endpoints from the key and host', () {
      final dsn = Dsn.parse('https://abc123@bugfree.example.com/ingest')!;

      expect(dsn.publicKey, 'abc123');
      expect(dsn.storeUrl.toString(), 'https://bugfree.example.com/ingest/v1/abc123/store');
      expect(dsn.sessionsUrl.toString(), 'https://bugfree.example.com/ingest/v1/abc123/sessions');
      expect(dsn.feedbackUrl.toString(), 'https://bugfree.example.com/ingest/v1/abc123/feedback');
    });

    test('keeps the port and falls back to /ingest', () {
      expect(Dsn.parse('http://key@localhost:3000')!.storeUrl.toString(), 'http://localhost:3000/ingest/v1/key/store');
    });

    test('turns an empty or malformed DSN into null', () {
      expect(Dsn.parse(''), isNull);
      expect(Dsn.parse(null), isNull);
      expect(Dsn.parse('http://localhost:3000/ingest'), isNull);
      expect(Dsn.parse('ftp://key@host'), isNull);
      expect(Dsn.parse('not a url'), isNull);
    });
  });
}
