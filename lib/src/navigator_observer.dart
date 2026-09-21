import 'package:flutter/widgets.dart';

import 'bugfree.dart';
import 'client.dart';
import 'event.dart';

/// Records route changes as breadcrumbs.
///
/// ```dart
/// MaterialApp(navigatorObservers: [BugfreeNavigatorObserver()])
/// ```
///
/// A route is named after its `RouteSettings.name`; give routes names (named
/// routes and go_router do) or the breadcrumb shows the route's type.
class BugfreeNavigatorObserver extends NavigatorObserver {
  /// Records to [client], or to the [Bugfree] client when null.
  BugfreeNavigatorObserver({BugfreeClient? client}) : _client = client;

  final BugfreeClient? _client;

  BugfreeClient get _target => _client ?? Bugfree.client;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _record('push', from: previousRoute, to: route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _record('pop', from: route, to: previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _record('replace', from: oldRoute, to: newRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record('remove', from: route, to: previousRoute);

  void _record(String action, {Route<dynamic>? from, Route<dynamic>? to}) {
    // Dialogs and bottom sheets are routes too; they are recorded all the same,
    // since "the error came from the dialog" is worth knowing.
    _target.addBreadcrumb(BugfreeBreadcrumb(
      category: 'navigation',
      message: '${routeName(from)} → ${routeName(to)}',
      data: action,
    ));
    // The tag names the route on screen now; one without a name clears it, so an
    // error there is not put down to the named route before it.
    if (action == 'remove') return;
    final name = to?.settings.name;
    _target.setTag('route', name == null || name.isEmpty ? null : name);
  }
}

/// The name a breadcrumb gives a route: its settings name, or its type.
String routeName(Route<dynamic>? route) {
  if (route == null) return '(none)';
  final name = route.settings.name;
  if (name != null && name.isNotEmpty) return name;
  return route.runtimeType.toString().split('<').first;
}
