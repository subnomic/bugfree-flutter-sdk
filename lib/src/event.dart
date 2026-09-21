/// The severity of an event.
enum BugfreeLevel {
  fatal,
  error,
  warning,
  info;

  String get value => name;
}

/// A single frame of a stack trace, innermost first.
class BugfreeFrame {
  BugfreeFrame({
    required this.function,
    required this.file,
    this.line = 0,
    this.column = 0,
    this.inApp = false,
    this.path,
    this.package,
  });

  String function;

  /// The file as the trace names it: `package:shop/cart.dart`, `dart:async`.
  String file;
  int line;
  int column;

  /// Whether the frame is in the application's own code.
  bool inApp;

  /// The file's path inside the project (`lib/cart.dart`), set for the
  /// application's frames; the interface links it to your editor.
  String? path;

  /// The Dart package the file belongs to, when it has one.
  String? package;

  Map<String, dynamic> toJson() => {
        'function': function,
        'file': file,
        'line': line,
        if (column > 0) 'column': column,
        'in_app': inApp,
        if (path != null && path!.isNotEmpty) 'path': path,
        if (package != null && package!.isNotEmpty) 'package': package,
      };
}

/// A step that happened before the error.
class BugfreeBreadcrumb {
  BugfreeBreadcrumb({
    required this.category,
    required this.message,
    this.level = 'info',
    this.data,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  String category;
  String message;
  String level;

  /// Details that do not fit the message, shown next to it.
  String? data;
  DateTime at;

  Map<String, dynamic> toJson() => {
        'category': category,
        'message': message,
        'level': level,
        if (data != null && data!.isNotEmpty) 'data': data,
        'at': at.toUtc().toIso8601String(),
      };
}

/// Who was using the application. Every field is optional.
class BugfreeUser {
  const BugfreeUser({this.id, this.email, this.name, this.ipAddress});

  final String? id;
  final String? email;

  /// Fills in the feedback dialog; not sent with events.
  final String? name;
  final String? ipAddress;

  Map<String, dynamic> toJson() => {
        if (id != null && id!.isNotEmpty) 'id': id,
        if (email != null && email!.isNotEmpty) 'email': email,
        if (ipAddress != null && ipAddress!.isNotEmpty) 'ip_address': ipAddress,
      };
}

/// The body sent to the ingest endpoint; the field names match the bugfree
/// ingest API one to one. `beforeSend` receives it and may change any field.
class BugfreeEvent {
  BugfreeEvent({
    required this.eventId,
    required this.level,
    required this.type,
    required this.message,
    this.culprit = '',
    this.environment = '',
    this.release = '',
    this.runtime = '',
    this.os = '',
    this.user,
    List<BugfreeFrame>? stacktrace,
    List<BugfreeBreadcrumb>? breadcrumbs,
    Map<String, dynamic>? tags,
    Map<String, dynamic>? extra,
    this.fingerprint,
    DateTime? occurredAt,
  })  : stacktrace = stacktrace ?? [],
        breadcrumbs = breadcrumbs ?? [],
        tags = tags ?? {},
        extra = extra ?? {},
        occurredAt = occurredAt ?? DateTime.now();

  final String eventId;
  BugfreeLevel level;
  String type;
  String message;
  String culprit;
  String environment;
  String release;
  String runtime;
  String os;
  BugfreeUser? user;
  List<BugfreeFrame> stacktrace;
  List<BugfreeBreadcrumb> breadcrumbs;
  Map<String, dynamic> tags;
  Map<String, dynamic> extra;

  /// Replaces the server's grouping: events with the same fingerprint form one issue.
  String? fingerprint;
  DateTime occurredAt;

  Map<String, dynamic> toJson() {
    final userJson = user?.toJson();
    return {
      'event_id': eventId,
      'level': level.value,
      'type': type,
      'message': message,
      if (culprit.isNotEmpty) 'culprit': culprit,
      'platform': 'flutter',
      if (environment.isNotEmpty) 'environment': environment,
      if (release.isNotEmpty) 'release': release,
      if (runtime.isNotEmpty) 'runtime': runtime,
      if (os.isNotEmpty) 'os': os,
      if (userJson != null && userJson.isNotEmpty) 'user': userJson,
      if (stacktrace.isNotEmpty) 'stacktrace': [for (final frame in stacktrace) frame.toJson()],
      if (breadcrumbs.isNotEmpty) 'breadcrumbs': [for (final crumb in breadcrumbs) crumb.toJson()],
      if (tags.isNotEmpty) 'tags': tags,
      if (extra.isNotEmpty) 'extra': extra,
      if (fingerprint != null && fingerprint!.isNotEmpty) 'fingerprint': fingerprint,
      'occurred_at': occurredAt.toUtc().toIso8601String(),
    };
  }
}
