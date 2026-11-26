// "Cascade X is out": the updater's dialog (core/updater.dart). Offered once a
// day on its own after the library loads, and from Settings > About > Check
// for updates. Download shows progress; a failure says why and offers the
// release page instead.
import 'package:flutter/material.dart';

import 'package:cascade/core/log.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/core/switch_back.dart';
import 'package:cascade/core/updater.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/widgets.dart';

bool _checking = false;

/// Looks for an update and offers it. [manual] is the Settings button: it
/// always looks and says when there is nothing; otherwise at most once a day,
/// quietly.
Future<void> maybeOfferUpdate(BuildContext context, Settings settings, {bool manual = false}) async {
  if (_checking || updateKind == null) {
    if (manual && context.mounted) toast(context, 'This copy of Cascade is updated another way (or is a development build).');
    return;
  }
  if (!manual && DateTime.now().difference(settings.lastUpdateCheck) < const Duration(hours: 20)) return;
  _checking = true;
  try {
    settings.markUpdateCheck();
    final u = await checkForUpdate(beta: settings.betaUpdates);
    if (!context.mounted) return;
    if (u == null) {
      if (manual) toast(context, 'Cascade is up to date.');
      return;
    }
    await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(u));
  } catch (e) {
    log('updater: $e');
    if (manual && context.mounted) toast(context, 'Could not look for updates: $e', error: true);
  } finally {
    _checking = false;
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.u);
  final AppUpdate u;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null until the download starts
  String? _error;

  Future<void> _update() async {
    setState(() => (_progress = 0, _error = null));
    try {
      final f = await downloadUpdate(widget.u, (got, total) {
        if (mounted && total > 0) setState(() => _progress = got / total);
      });
      if (mounted) setState(() => _progress = 1);
      await installUpdate(f); // quits this app
    } catch (e) {
      log('updater: install failed: $e');
      if (mounted) setState(() => (_progress = null, _error = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return AlertDialog(
      backgroundColor: K.panel,
      title: Text('Cascade ${widget.u.version} is out', style: Txt.section()),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              busy ? 'Downloading. Cascade restarts on its own when it is ready.' : 'Update now? Cascade closes and opens again on the new version.',
              style: ts(13, c: K.text2, h: 1.4),
            ),
            if (busy) ...[const SizedBox(height: 14), LinearProgressIndicator(value: _progress == 0 ? null : _progress)],
            if (_error case final e?) ...[const SizedBox(height: 12), Text('Update failed: $e', style: ts(12, c: K.error, h: 1.4))],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => openLink(widget.u.releaseUrl), child: Text(_error == null ? "What's new" : 'Open release page')),
        if (!busy) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
        if (!busy) TextButton(onPressed: _update, child: Text(_error == null ? 'Update now' : 'Try again')),
      ],
    );
  }
}

/// Settings > About > Switch back: asks first, then downloads and installs the
/// classic app and closes this one (core/switch_back.dart).
Future<void> showSwitchBackDialog(BuildContext context) => showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _SwitchBackDialog());

class _SwitchBackDialog extends StatefulWidget {
  const _SwitchBackDialog();

  @override
  State<_SwitchBackDialog> createState() => _SwitchBackDialogState();
}

class _SwitchBackDialogState extends State<_SwitchBackDialog> {
  double? _progress;
  String? _error;

  Future<void> _go() async {
    setState(() => (_progress = 0, _error = null));
    try {
      final app = await findClassicApp();
      if (app == null) throw StateError('No release has the classic app for this computer.');
      final f = await downloadUpdate(app, (got, total) {
        if (mounted && total > 0) setState(() => _progress = got / total);
      });
      await switchBack(f); // quits this app
    } catch (e) {
      log('switch back failed: $e');
      if (mounted) setState(() => (_progress = null, _error = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return AlertDialog(
      backgroundColor: K.panel,
      title: Text('Switch back to the classic app?', style: Txt.section()),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              busy
                  ? 'Downloading the classic app. It opens on its own, and this one is removed.'
                  : 'Your settings and sign-in go back with you. The classic app is installed and opens, and this app is removed. The classic app is retired at Cascade 3.0.',
              style: ts(13, c: K.text2, h: 1.4),
            ),
            if (busy) ...[const SizedBox(height: 14), LinearProgressIndicator(value: _progress == 0 ? null : _progress)],
            if (_error case final e?) ...[const SizedBox(height: 12), Text('Could not switch back: $e', style: ts(12, c: K.error, h: 1.4))],
          ],
        ),
      ),
      actions: [
        if (!busy) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Stay here')),
        if (!busy) TextButton(onPressed: _go, child: Text(_error == null ? 'Switch back' : 'Try again')),
      ],
    );
  }
}
