// Sign in with Quick Connect: type the server, get a code, approve it from
// another signed-in app (Cascade's Settings > Account, or Jellyfin's own).
// No password field on purpose. Also the account panel used by Settings.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/scopes.dart';

class SignIn extends StatefulWidget {
  const SignIn({super.key});

  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final _url = TextEditingController();
  Jellyfin? _jf;
  String? _code, _serverName, _error;
  bool _busy = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    _url.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final jf = await Jellyfin.forServer(_url.text);
      final name = await jf.serverName();
      final qc = await jf.quickConnectStart();
      final started = DateTime.now();
      _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
        if (DateTime.now().difference(started).inMinutes >= 5) return _cancel('The code expired. Get a new one.');
        if (!await jf.quickConnectApproved(qc.secret) || !mounted || _poll != t) return;
        t.cancel();
        try {
          await jf.quickConnectFinish(qc.secret);
          if (!mounted) return;
          PlayerScope.read(context).jf = jf;
          await LibraryScope.read(context).use(jf);
        } catch (e) {
          _cancel('Approved, but signing in failed: $e');
        }
      });
      setState(() {
        _jf = jf;
        _serverName = name;
        _code = qc.code;
      });
    } catch (e) {
      setState(() => _error = 'Could not reach a Jellyfin server with Quick Connect there ($e).');
    }
    setState(() => _busy = false);
  }

  void _cancel([String? why]) {
    _poll?.cancel();
    _poll = null;
    if (mounted) {
      setState(() {
        _code = null;
        _error = why;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: K.root,
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Image.asset('assets/icon.png', width: 64, height: 64),
              const SizedBox(height: 16),
              Text(
                'Sign in to Jellyfin',
                textAlign: TextAlign.center,
                style: ts(24, w: FontWeight.w700),
              ),
              const SizedBox(height: 24),
              if (_code == null) ...[
                TextField(
                  controller: _url,
                  autofocus: true,
                  enabled: !_busy,
                  style: ts(15),
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _start(),
                  decoration: InputDecoration(
                    labelText: 'Server address',
                    hintText: 'http://192.168.1.94:8096',
                    filled: true,
                    fillColor: K.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _start,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: Text(_busy ? 'Connecting…' : 'Get a Quick Connect code'),
                ),
              ] else ...[
                Text(
                  'Approve this code on ${_serverName ?? _jf?.server}',
                  textAlign: TextAlign.center,
                  style: ts(14, c: K.text2),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _code!,
                  textAlign: TextAlign.center,
                  style: ts(44, w: FontWeight.w700, ls: 8, c: K.accent),
                ),
                const SizedBox(height: 12),
                Text(
                  'In another signed-in app: Cascade\'s Settings > Account, or Jellyfin\'s user menu > Quick Connect.',
                  textAlign: TextAlign.center,
                  style: ts(13, c: K.text3),
                ),
                const SizedBox(height: 20),
                const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
                const SizedBox(height: 12),
                TextButton(onPressed: _cancel, child: const Text('Cancel')),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: ts(13, c: const Color(0xFFFF453A)),
                ),
              ],
              const SizedBox(height: 24),
              TextButton(
                onPressed: LibraryScope.read(context).useDemo,
                child: Text('Look around the demo instead', style: ts(13, c: K.text3)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Settings for now: who is signed in, and Sign out.
class AccountPanel extends StatelessWidget {
  const AccountPanel({super.key, this.color = K.text});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final who = lib.demo ? 'You are looking at the demo.' : 'Signed in as ${lib.jf?.userName ?? '?'} on ${lib.jf?.server ?? '?'}';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Settings',
              style: ts(28, w: FontWeight.w700, c: color),
            ),
            const SizedBox(height: 8),
            Text(
              who,
              textAlign: TextAlign.center,
              style: ts(14, c: K.text3),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () async {
                await PlayerScope.read(context).stop();
                await lib.signOut();
              },
              child: Text(lib.demo ? 'Leave the demo' : 'Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
