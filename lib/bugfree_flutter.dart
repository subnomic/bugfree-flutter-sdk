/// The bugfree SDK for Flutter applications.
///
/// ```dart
/// import 'package:bugfree_flutter/bugfree_flutter.dart';
///
/// Future<void> main() async {
///   await Bugfree.init(const BugfreeOptions(
///     dsn: String.fromEnvironment('BUGFREE_DSN'),
///     environment: 'production',
///     release: 'shop@1.4.0+42',
///   ));
///   runApp(const ShopApp());
/// }
/// ```
library;

export 'src/bugfree.dart' show Bugfree;
export 'src/client.dart' show BugfreeClient, sdkVersion;
export 'src/event.dart' show BugfreeBreadcrumb, BugfreeEvent, BugfreeFrame, BugfreeLevel, BugfreeUser;
export 'src/feedback_dialog.dart' show BugfreeFeedbackDialog, BugfreeFeedbackLabels, showBugfreeFeedbackDialog;
export 'src/http_client.dart' show BugfreeHttpClient;
export 'src/navigator_observer.dart' show BugfreeNavigatorObserver;
export 'src/options.dart' show BeforeSend, BugfreeOptions;
