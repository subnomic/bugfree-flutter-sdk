import 'dart:collection';

import 'event.dart';

/// The last breadcrumbs, oldest first; the oldest is dropped once it is full.
class BreadcrumbBuffer {
  BreadcrumbBuffer(this.capacity);

  final int capacity;
  final _items = ListQueue<BugfreeBreadcrumb>();

  void add(BugfreeBreadcrumb crumb) {
    if (capacity <= 0) return;
    // A message is capped, so one enormous log line cannot fill the event.
    if (crumb.message.length > 500) crumb.message = '${crumb.message.substring(0, 500)}…';
    _items.addLast(crumb);
    while (_items.length > capacity) {
      _items.removeFirst();
    }
  }

  List<BugfreeBreadcrumb> list() => List.of(_items);

  void clear() => _items.clear();
}
