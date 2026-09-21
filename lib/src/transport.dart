import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The pause after a 429 that names no wait of its own.
const defaultRetryAfter = Duration(minutes: 1);

/// Sends events to the ingest endpoint, one after another from a bounded queue.
///
/// Reporting must never break the application: every failure is swallowed, a full
/// queue drops the new event instead of growing, and a 429 answer pauses sending
/// for as long as the server asks. An event that could not be sent because the
/// device was offline is kept, a few at most, and tried again with the next one.
class Transport {
  Transport(
    this.storeUrl, {
    required this.client,
    this.maxQueueSize = 100,
    this.maxDeferred = 30,
    this.timeout = const Duration(seconds: 10),
    this.retryDelay = const Duration(milliseconds: 500),
    this.log,
  });

  final Uri storeUrl;
  final http.Client client;
  final int maxQueueSize;
  final int maxDeferred;
  final Duration timeout;
  final Duration retryDelay;
  final void Function(String message)? log;

  final _queue = ListQueue<_Pending>();
  // Events that failed for want of a network; sent again after the next event.
  final _deferred = ListQueue<Map<String, dynamic>>();
  bool _draining = false;
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether the server asked to wait.
  bool get paused => DateTime.now().isBefore(_pausedUntil);

  /// Queued plus being sent.
  int get pending => _queue.length + (_draining ? 1 : 0);

  /// Events waiting for the network to come back.
  int get deferred => _deferred.length;

  /// Queues an event; completes with the server's answer, or null.
  Future<Map<String, dynamic>?> send(Map<String, dynamic> event) {
    if (paused) {
      log?.call('server asked to wait, event dropped');
      return Future.value(null);
    }
    if (_queue.length >= maxQueueSize) {
      log?.call('queue is full, event dropped');
      return Future.value(null);
    }
    final pending = _Pending(event);
    _queue.add(pending);
    unawaited(_drain());
    return pending.completer.future;
  }

  /// Sends the events kept while offline, for instance when the app comes back to
  /// the foreground.
  void retryDeferred() {
    if (_deferred.isEmpty || paused) return;
    while (_deferred.isNotEmpty && _queue.length < maxQueueSize) {
      _queue.add(_Pending(_deferred.removeFirst(), deferred: true));
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final pending = _queue.removeFirst();
        Map<String, dynamic>? result;
        try {
          // Events queued before a 429 arrived are dropped with the rest.
          result = paused ? null : await _post(pending);
        } catch (error) {
          log?.call('event could not be sent: $error');
        }
        if (!pending.completer.isCompleted) pending.completer.complete(result);
      }
    } finally {
      _draining = false;
    }
  }

  Future<Map<String, dynamic>?> _post(_Pending pending) async {
    final body = jsonEncode(pending.event);
    for (var attempt = 0; attempt < 2; attempt++) {
      http.Response response;
      try {
        response = await client
            .post(storeUrl, headers: const {'Content-Type': 'application/json'}, body: body)
            .timeout(timeout);
      } catch (error) {
        if (attempt == 0) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        _defer(pending.event);
        log?.call('event could not be sent, kept for later: $error');
        return null;
      }

      if (response.statusCode == 429) {
        _pausedUntil = DateTime.now().add(parseRetryAfter(response.headers['retry-after']));
        log?.call('server is rate limiting, sending paused');
        return null;
      }
      // Client errors (an invalid key, a malformed body) are not retried.
      if (response.statusCode >= 400 && response.statusCode < 500) {
        log?.call('server rejected the event (${response.statusCode})');
        return null;
      }
      if (response.statusCode >= 500) {
        if (attempt == 0) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        log?.call('server could not store the event (${response.statusCode})');
        return null;
      }

      // The network works again: what waited for it goes next.
      if (!pending.deferred) retryDeferred();
      try {
        final decoded = jsonDecode(response.body);
        return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return null;
  }

  void _defer(Map<String, dynamic> event) {
    if (maxDeferred <= 0) return;
    _deferred.addLast(event);
    while (_deferred.length > maxDeferred) {
      _deferred.removeFirst();
    }
  }

  /// Waits until the queue is empty or [timeout] passed; true when it emptied.
  Future<bool> flush([Duration timeout = const Duration(seconds: 2)]) async {
    final deadline = DateTime.now().add(timeout);
    while (pending > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return pending == 0;
  }
}

class _Pending {
  _Pending(this.event, {this.deferred = false});

  final Map<String, dynamic> event;
  final bool deferred;
  final completer = Completer<Map<String, dynamic>?>();
}

/// Reads a Retry-After header, seconds or an HTTP date.
Duration parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null || value.trim().isEmpty) return defaultRetryAfter;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) return seconds > 0 ? Duration(seconds: seconds) : defaultRetryAfter;
  try {
    final at = parseHttpDate(value.trim());
    final difference = at.difference(now ?? DateTime.now());
    return difference > Duration.zero ? difference : defaultRetryAfter;
  } on FormatException {
    return defaultRetryAfter;
  }
}

// HttpDate lives in dart:io, which a web build does not have. The dates servers
// send ("Sun, 06 Nov 1994 08:49:37 GMT", and the older "Sunday, 06-Nov-94") are
// read here; any other form counts as a Retry-After that names no wait.
const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Reads an HTTP date as UTC; throws a [FormatException] for anything else.
DateTime parseHttpDate(String value) {
  final match = RegExp(r'(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(value);
  if (match == null) throw const FormatException('not an HTTP date');
  final month = _months[match.group(2)!.toLowerCase()];
  if (month == null) throw const FormatException('not an HTTP date');
  var year = int.parse(match.group(3)!);
  if (year < 100) year += year < 70 ? 2000 : 1900;
  return DateTime.utc(year, month, int.parse(match.group(1)!), int.parse(match.group(4)!), int.parse(match.group(5)!),
      int.parse(match.group(6)!));
}
