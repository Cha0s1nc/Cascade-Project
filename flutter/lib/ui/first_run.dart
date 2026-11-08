// The first-run wizard, after the first sign-in: the few choices worth making
// up front, as the desktop's (renderer.js FIRSTRUN_STEPS). Libraries (only
// when there is a choice), crossfade, streaming quality, and how Now Playing
// looks. The desktop's button, translation and telemetry steps have nothing
// to set here yet. Bumping the revision shows the steps added since.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/library.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/ui/widgets.dart';

const firstRunRevision = 1;
const _key = 'flutterWizardSeen';

/// Shows the wizard once a signed-in library has loaded, unless seen.
bool _showing = false;

Future<void> maybeShowFirstRun(BuildContext context, Library lib, Settings s) async {
  if (lib.demo || lib.jf == null || _showing) return;
  _showing = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getInt(_key) ?? 0) >= firstRunRevision || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FirstRun(lib: lib, s: s),
    );
    await prefs.setInt(_key, firstRunRevision);
  } finally {
    _showing = false;
  }
}

class _FirstRun extends StatefulWidget {
  const _FirstRun({required this.lib, required this.s});
  final Library lib;
  final Settings s;

  @override
  State<_FirstRun> createState() => _FirstRunState();
}

class _FirstRunState extends State<_FirstRun> {
  int _step = 0;

  List<(String, String, Widget Function())> get _steps => [
    if (widget.lib.musicLibs.length > 1 || widget.lib.movieLibs.isNotEmpty || widget.lib.showLibs.isNotEmpty)
      ('Your libraries', 'Pick what Cascade shows. You can change this in Settings > Library.', _libraries),
    ('Crossfade', 'Fade each song into the next, or play them back to back.', _crossfade),
    ('Streaming quality', 'Above this, the server converts files down. Original plays them as they are.', _quality),
    ('Now Playing', 'Where the controls go, and whether what is next peeks out behind the cover.', _look),
  ];

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    final (title, voice, body) = steps[_step];
    final last = _step == steps.length - 1;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.s, widget.lib]),
      builder: (context, _) => AlertDialog(
        backgroundColor: K.panel,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WELCOME TO CASCADE · ${_step + 1} OF ${steps.length}', style: Txt.caps()),
            const SizedBox(height: 8),
            Text(title, style: Txt.title()),
            const SizedBox(height: 4),
            Text(voice, style: Txt.voice()),
          ],
        ),
        content: SizedBox(width: 460, child: SingleChildScrollView(child: body())),
        actions: [
          if (_step > 0) TextButton(onPressed: () => setState(() => _step--), child: const Text('Back')),
          Pill(last ? 'Start listening' : 'Next', onTap: () => last ? Navigator.pop(context) : setState(() => _step++)),
        ],
      ),
    );
  }

  Widget _check(String label, bool on, ValueChanged<bool> set) => CheckboxListTile(
    value: on,
    onChanged: (v) => set(v ?? false),
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    activeColor: K.accent,
    checkColor: K.ink,
    title: Text(label, style: ts(13)),
  );

  Widget _libraries() {
    final lib = widget.lib;
    final music = lib.jf?.libraryIds ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lib.musicLibs)
          _check('${l['Name']}', music.contains(l['Id']), (on) {
            final ids = {...music};
            on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
            if (ids.isNotEmpty) lib.setLibraries(music: ids.toList());
          }),
        for (final l in lib.movieLibs)
          _check('${l['Name']} (movies)', lib.movieIds.contains(l['Id']), (on) {
            final ids = {...lib.movieIds};
            on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
            lib.setLibraries(movies: ids.toList());
          }),
        for (final l in lib.showLibs)
          _check('${l['Name']} (shows)', lib.showIds.contains(l['Id']), (on) {
            final ids = {...lib.showIds};
            on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
            lib.setLibraries(shows: ids.toList());
          }),
      ],
    );
  }

  Widget _crossfade() {
    final s = widget.s;
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Crossfade', style: ts(14)),
          value: s.crossfadeEnabled,
          onChanged: (v) => s.setCrossfade(enabled: v),
        ),
        if (s.crossfadeEnabled)
          Row(
            children: [
              Expanded(
                child: safeSlider(
                  Slider(
                    value: s.crossfadeSeconds.toDouble(),
                    min: 1,
                    max: 15,
                    divisions: 14,
                    onChanged: (v) => s.setCrossfade(seconds: v.round()),
                  ),
                ),
              ),
              Text('${s.crossfadeSeconds} s', style: ts(13, c: K.text2)),
            ],
          ),
      ],
    );
  }

  Widget _quality() => RadioGroup<int>(
    groupValue: widget.s.maxStreamingBitrate,
    onChanged: (v) => v == null ? null : widget.s.setMaxBitrate(v),
    child: Column(
      children: [
        for (final q in qualitySteps)
          RadioListTile<int>(
            value: q.bitrate,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(q.label, style: ts(13)),
          ),
      ],
    ),
  );

  Widget _look() {
    final s = widget.s;
    return RadioGroup<String>(
      groupValue: s.nowPlayingLayout,
      onChanged: (v) => v == null ? null : s.setNowPlayingLayout(v),
      child: Column(
        children: [
          for (final (v, label, sub) in [
            ('bar', 'Player bar stays', 'Now Playing covers the page; the player bar stays at the bottom.'),
            ('under', 'Controls under the art', 'Now Playing takes the window, with the controls under the cover.'),
            ('focus', 'Focus', 'The lyrics take the window; the controls hide until the mouse moves.'),
          ])
            RadioListTile<String>(
              value: v,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(label, style: ts(13, w: FontWeight.w500)),
              subtitle: Text(sub, style: ts(12, c: K.text3)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text("Show what's next behind the art", style: ts(13)),
            value: s.showArtStack,
            onChanged: s.setShowArtStack,
          ),
        ],
      ),
    );
  }
}
