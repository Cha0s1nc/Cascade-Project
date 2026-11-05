// Theme: the Now Playing look and Style Tuning, the lyric knobs the desktop
// and the Swift apps share (core/lyric_style.dart), over the shipped values.
// Only knobs this app's lyrics actually use are offered; changes are stored
// under the desktop's lyricStyle key and apply live.
import 'package:flutter/material.dart';

import 'package:cascade/core/lyric_style.dart';
import 'package:cascade/core/tuning_defaults.dart';
import 'package:cascade/ui/lyrics_view.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

/// The knobs the Flutter lyrics draw with. ponytail: the held-note swell,
/// word lift, ripple, scroll lead and album-color knobs come with those
/// effects.
const _used = {
  'currentLinePosition',
  'lineGap',
  'pastScale',
  'pastOpacity',
  'pastBlur',
  'next1Opacity',
  'next1Blur',
  'next2Opacity',
  'next2Blur',
  'next3Opacity',
  'next3Blur',
  'farBlur',
  'browsingOpacity',
  'browsingBlur',
  'unsungOpacity',
  'backgroundVocalSize',
  'backgroundVocalOpacity',
  'fadeSeconds',
  'lyricsDelay',
  'controlsIdleSeconds',
};

class ThemePage extends StatelessWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = PlayerScope.of(context).settings;
    final json = tuningJson;
    final tuning = json == null ? null : LyricStyleTuning(TuningDefaults(json, platform: narrow(context) ? 'ios' : 'desktop'));
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final knobs = [
          for (final k in tuning?.knobs ?? const <LyricKnob>[])
            if (_used.contains(k.key)) k,
        ];
        final sections = <String, List<LyricKnob>>{};
        for (final k in knobs) {
          sections.putIfAbsent(k.section, () => []).add(k);
        }
        final style = tuning?.lyricStyleFrom(s.lyricStyle) ?? const <String, double>{};
        void set(String key, double v) => s.setLyricStyle(tuning!.lyricStyleChanges({...style, key: v}));
        return ListView(
          padding: pagePaddingOf(context),
          children: [
            PageHeader(
              'Theme',
              voice: 'How Now Playing and the lyrics look.',
              actions: [if (s.lyricStyle.isNotEmpty) Pill('Back to the shipped look', primary: false, onTap: () => s.setLyricStyle({}))],
            ),
            SectionTitle('Now Playing', top: 0),
            _Row(
              'Layout',
              DropdownButton<String>(
                value: s.nowPlayingLayout,
                dropdownColor: K.surface2,
                style: ts(13),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'bar', child: Text('Player bar stays')),
                  DropdownMenuItem(value: 'under', child: Text('Controls under the art')),
                  DropdownMenuItem(value: 'focus', child: Text('Focus')),
                ],
                onChanged: (v) => s.setNowPlayingLayout(v!),
              ),
            ),
            _Row("Show what's next behind the art", Switch(value: s.showArtStack, onChanged: s.setShowArtStack)),
            if (tuning == null) Text('The style file did not load.', style: ts(13, c: K.error)),
            for (final MapEntry(key: section, value: list) in sections.entries) ...[
              SectionTitle('Lyrics: $section'),
              for (final k in list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(width: 240, child: Text(k.label, style: ts(13))),
                      Expanded(
                        child: Slider(
                          value: style[k.key]!.clamp(k.min, k.max),
                          min: k.min,
                          max: k.max,
                          divisions: ((k.max - k.min) / k.step).round().clamp(1, 1000),
                          onChanged: (v) => set(k.key, v),
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                          '${style[k.key]!.toStringAsFixed(k.step < 0.1 ? 2 : 1)}${k.unit == 'px'
                              ? ' px'
                              : k.unit == 's'
                              ? ' s'
                              : ''}',
                          textAlign: TextAlign.right,
                          style: ts(12, c: (style[k.key]! - k.value).abs() > 1e-9 ? K.accent : K.text3),
                        ),
                      ),
                      IconBtn(Icons.restart_alt_rounded, 'Shipped value', (style[k.key]! - k.value).abs() > 1e-9 ? () => set(k.key, k.value) : null, size: 16),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.trailing);
  final String label;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: ts(14, w: FontWeight.w500)),
        ),
        trailing,
      ],
    ),
  );
}
