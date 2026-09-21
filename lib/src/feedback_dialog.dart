import 'package:flutter/material.dart';

import 'bugfree.dart';
import 'client.dart';

/// The texts of the feedback dialog; pass your own to translate it.
class BugfreeFeedbackLabels {
  const BugfreeFeedbackLabels({
    this.title = 'Report a problem',
    this.intro = 'Tell us what happened. The report is tied to the error you just saw.',
    this.name = 'Name',
    this.email = 'Email',
    this.message = 'What happened?',
    this.cancel = 'Cancel',
    this.submit = 'Send',
    this.sending = 'Sending…',
    this.failed = 'The report could not be sent. Try again.',
  });

  final String title;
  final String intro;
  final String name;
  final String email;
  final String message;
  final String cancel;
  final String submit;
  final String sending;
  final String failed;
}

/// Asks the user what happened and sends the answer, tied to [eventId] or the
/// latest captured event. Completes with true when feedback was sent, false when
/// the dialog was closed.
///
/// The user set with `setUser` fills in the name and email fields.
Future<bool> showBugfreeFeedbackDialog(
  BuildContext context, {
  String? eventId,
  BugfreeFeedbackLabels labels = const BugfreeFeedbackLabels(),
  BugfreeClient? client,
}) async {
  final target = client ?? Bugfree.client;
  if (!target.enabled) return false;
  final sent = await showDialog<bool>(
    context: context,
    builder: (_) => BugfreeFeedbackDialog(
      client: target,
      eventId: eventId ?? target.lastEventId,
      labels: labels,
    ),
  );
  return sent ?? false;
}

/// The dialog [showBugfreeFeedbackDialog] opens; usable on its own in a route of
/// your own.
class BugfreeFeedbackDialog extends StatefulWidget {
  const BugfreeFeedbackDialog({
    super.key,
    required this.client,
    this.eventId,
    this.labels = const BugfreeFeedbackLabels(),
  });

  final BugfreeClient client;
  final String? eventId;
  final BugfreeFeedbackLabels labels;

  @override
  State<BugfreeFeedbackDialog> createState() => _BugfreeFeedbackDialogState();
}

class _BugfreeFeedbackDialogState extends State<BugfreeFeedbackDialog> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  final _message = TextEditingController();
  bool _sending = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final user = widget.client.user;
    _name = TextEditingController(text: user?.name ?? '');
    _email = TextEditingController(text: user?.email ?? '');
    _message.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _failed = false;
    });
    final sent = await widget.client.captureFeedback(
      message: _message.text.trim(),
      name: _name.text.trim(),
      email: _email.text.trim(),
      eventId: widget.eventId,
    );
    if (!mounted) return;
    if (sent) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _sending = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final canSend = !_sending && _message.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(labels.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(labels.intro, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              enabled: !_sending,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: labels.name),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _email,
              enabled: !_sending,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: labels.email),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('bugfree-feedback-message'),
              controller: _message,
              enabled: !_sending,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              decoration: InputDecoration(labelText: labels.message),
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(labels.failed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
          child: Text(labels.cancel),
        ),
        FilledButton(
          onPressed: canSend ? _submit : null,
          child: Text(_sending ? labels.sending : labels.submit),
        ),
      ],
    );
  }
}
