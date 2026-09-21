import 'event.dart';

/// The largest number of frames sent in one event.
const maxFrames = 50;

/// The package of this SDK; its own frames are left out of a captured stack.
const sdkPackage = 'bugfree_flutter';

/// A stack trace turned into frames.
class ParsedStack {
  ParsedStack(this.frames, {this.symbolic = true});

  final List<BugfreeFrame> frames;

  /// False for the trace of a build made with `--split-debug-info` or
  /// `--obfuscate`: it names addresses instead of functions and files.
  final bool symbolic;
}

// "#0      CartState.checkout (package:shop/cart.dart:42:7)", the Dart VM.
final _vmFrame = RegExp(r'^#\d+\s+(.+?) \((.+?)\)$');
// "    at Object.checkout (http://localhost/main.dart.js:1234:56)", V8 on the web.
final _v8Frame = RegExp(r'^\s*at (?:(.+?) \()?(.+?)\)?$');
// "checkout@http://localhost/main.dart.js:1234:56", Firefox and Safari.
final _geckoFrame = RegExp(r'^(.*?)@(.+)$');
// "package:shop/cart.dart 42:7  CartState.checkout", the terse format of
// package:stack_trace and of debug builds on the web.
final _terseFrame = RegExp(r'^(\S+) (\d+)(?::(\d+))?\s+(.+)$');
// "file:line:column" or "file:line" at the end of a location.
final _position = RegExp(r'^(.*?):(\d+)(?::(\d+))?$');

/// Whether a trace comes from a build without symbols (`--split-debug-info`).
bool isNonSymbolic(String trace) =>
    trace.contains('*** *** ***') || RegExp(r'^#\d+\s+abs [0-9a-f]+', multiLine: true).hasMatch(trace);

/// Turns a stack trace into frames, innermost first.
///
/// [inAppPackages] names the packages that are the application's own code; a
/// frame of any other package, of the Dart SDK or of Flutter is library code.
ParsedStack parseStackTrace(StackTrace? stackTrace, {Set<String> inAppPackages = const {}}) {
  final text = stackTrace?.toString() ?? '';
  if (text.trim().isEmpty) return ParsedStack([]);
  if (isNonSymbolic(text)) return ParsedStack([], symbolic: false);

  final frames = <BugfreeFrame>[];
  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty || line.contains('<asynchronous suspension>')) continue;
    final frame = _parseLine(line, inAppPackages);
    if (frame != null) frames.add(frame);
  }

  // The SDK's own frames above the caller say nothing about the error.
  var start = 0;
  while (start < frames.length && frames[start].package == sdkPackage) {
    start++;
  }
  final trimmed = frames.sublist(start < frames.length ? start : 0);
  return ParsedStack(trimmed.length > maxFrames ? trimmed.sublist(0, maxFrames) : trimmed);
}

BugfreeFrame? _parseLine(String line, Set<String> inAppPackages) {
  String function;
  String location;
  var lineNumber = 0;
  var column = 0;

  RegExpMatch? match;
  if ((match = _vmFrame.firstMatch(line)) != null) {
    function = match!.group(1)!;
    location = match.group(2)!;
  } else if ((match = _terseFrame.firstMatch(line)) != null) {
    function = match!.group(4)!.trim();
    location = match.group(1)!;
    lineNumber = int.tryParse(match.group(2)!) ?? 0;
    column = int.tryParse(match.group(3) ?? '') ?? 0;
  } else if ((match = _v8Frame.firstMatch(line)) != null) {
    function = match!.group(1) ?? '<anonymous>';
    location = match.group(2)!;
  } else if ((match = _geckoFrame.firstMatch(line)) != null) {
    function = match!.group(1)!.isEmpty ? '<anonymous>' : match.group(1)!;
    location = match.group(2)!;
  } else {
    return null;
  }

  if (lineNumber == 0) {
    final position = _position.firstMatch(location);
    if (position != null) {
      location = position.group(1)!;
      lineNumber = int.tryParse(position.group(2)!) ?? 0;
      column = int.tryParse(position.group(3) ?? '') ?? 0;
    }
  }

  final file = _normalizeFile(location);
  final package = packageOf(file);
  final inApp = _isInApp(file, package, inAppPackages);
  return BugfreeFrame(
    function: function.replaceAll('<anonymous closure>', '<fn>'),
    file: file,
    line: lineNumber,
    column: column,
    inApp: inApp,
    path: inApp ? projectPath(file) : null,
    package: package,
  );
}

/// Writes the file of a debug web build (`packages/shop/cart.dart`) as the VM
/// does (`package:shop/cart.dart`), so both group into the same issue.
String _normalizeFile(String location) {
  if (location.startsWith('packages/')) return 'package:${location.substring('packages/'.length)}';
  return location;
}

/// The package a file belongs to: `shop` for `package:shop/cart.dart`.
String? packageOf(String file) {
  if (!file.startsWith('package:')) return null;
  final rest = file.substring('package:'.length);
  final slash = rest.indexOf('/');
  return slash > 0 ? rest.substring(0, slash) : null;
}

bool _isInApp(String file, String? package, Set<String> inAppPackages) {
  if (package != null) return inAppPackages.contains(package);
  if (file.startsWith('dart:') || file.startsWith('org-dartlang-sdk:')) return false;
  // A file path is the application's own when it is not in the pub cache or the
  // Flutter SDK: tests and some debug builds name the entry point that way.
  if (file.startsWith('file://')) {
    return !file.contains('/.pub-cache/') && !file.contains('/flutter/packages/') && !file.contains('/flutter/bin/');
  }
  return false;
}

/// The file's path inside the project, the way the editor link needs it:
/// `package:shop/src/cart.dart` is `lib/src/cart.dart`.
String? projectPath(String file) {
  if (file.startsWith('package:')) {
    final rest = file.substring('package:'.length);
    final slash = rest.indexOf('/');
    return slash > 0 ? 'lib/${rest.substring(slash + 1)}' : null;
  }
  if (file.startsWith('file://')) {
    final path = Uri.tryParse(file)?.path ?? file.substring('file://'.length);
    for (final folder in ['/lib/', '/test/', '/integration_test/', '/bin/']) {
      final index = path.lastIndexOf(folder);
      if (index >= 0) return path.substring(index + 1);
    }
  }
  return null;
}

/// Finds the application's package from where [Bugfree.init] was called: the
/// first frame of a package that is neither this SDK nor Flutter's own.
String? callerPackage(StackTrace stackTrace) {
  for (final frame in parseStackTrace(stackTrace).frames) {
    final package = frame.package;
    if (package == null || package == sdkPackage || package == 'flutter' || package == 'flutter_test') continue;
    return package;
  }
  return null;
}
