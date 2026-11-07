// The Style menu, as the Electron app's customization editor: opened from
// the brush in the title bar or Now Playing, or from the Style buttons in
// Settings. With a song playing it opens inside Now Playing, beside the live
// lyrics, so every change shows at once. With nothing playing it opens on
// its own and the look controls are off, since there would be nothing to see
// them change (the lyrics source and the interface size still work).
// Tabs: Appearance, Now Playing, Lyrics, Crossfade, Presets. Every control
// saves at once; "Reset this tab" puts that tab's shipped values back and
// "Undo changes since opening" puts back what was there when it opened.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/lyric_style.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/core/tuning_defaults.dart';
import 'package:cascade/ui/controls.dart';
import 'package:cascade/ui/lyrics_view.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

/// The lyric knobs the Flutter lyrics draw with. ponytail: the background
/// color knobs come with the album-color background.
const lyricKnobsUsed = {
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
  'wordLift',
  'heldFullSeconds',
  'heldMinStrength',
  'heldLift',
  'heldScale',
  'heldSettleSeconds',
  'backgroundVocalSize',
  'backgroundVocalOpacity',
  'fadeSeconds',
  'rippleSeconds',
  'lyricsDelay',
  'scrollLead',
  'tightScrollLead',
  'controlsIdleSeconds',
};

const styleTabs = [
  ('appearance', 'Appearance', null),
  ('nowplaying', 'Now Playing', null),
  ('lyrics', 'Lyrics', null),
  ('crossfade', 'Crossfade', null),
  ('presets', 'Presets', null),
];

/// Open the Style menu on [tab]: inside Now Playing when a song is
/// playing, on its own otherwise.
void openStyleMenu(BuildContext context, {String tab = 'appearance'}) {
  final p = PlayerScope.read(context);
  final np = NowPlayingScope.maybeRead(context);
  if (p.song != null && np != null && !narrow(context)) {
    // The brush again closes it.
    if (np.editing != null) return np.stopEditing();
    np.editStyle(tab);
    return;
  }
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 350),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      // The root navigator sits above the scopes, so bring the player along.
      pageBuilder: (_, _, _) => PlayerScope(
        player: p,
        child: _StandaloneStyle(tab: tab),
      ),
      transitionsBuilder: (_, a, _, child) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(-0.04, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: editorCurve)),
          child: child,
        ),
      ),
    ),
  );
}

class _StandaloneStyle extends StatelessWidget {
  const _StandaloneStyle({required this.tab});
  final String tab;

  @override
  Widget build(BuildContext context) => Material(
    color: K.root.withValues(alpha: 0.96),
    child: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          // On a phone there is no room beside the lyrics, so with a song
          // playing the look controls stay on and you check after closing.
          child: StyleMenu(tab: tab, live: narrow(context) && PlayerScope.read(context).song != null, onClose: () => Navigator.pop(context)),
        ),
      ),
    ),
  );
}

/// What the look was when the menu opened, for Undo.
class _Snapshot {
  _Snapshot(Settings s) : json = jsonEncode(_lookOf(s)), lyricStyle = {...s.lyricStyle};
  final String json;
  final Map<String, double> lyricStyle;
}

Map<String, Object?> _lookOf(Settings s) => {
  'buttonStyle': s.buttonStyle,
  'reduceMotion': s.reduceMotion,
  'uiScale': s.uiScale,
  'nowPlayingLayout': s.nowPlayingLayout,
  'showArtStack': s.showArtStack,
  'bgDim': s.bgDim,
  'colorFade': s.colorFade,
  'colorFadeSeconds': s.colorFadeSeconds,
  'lyricScale': s.lyricScale,
  'plainLyricScale': s.plainLyricScale,
  'lyricsForcedSource': s.lyricsSource,
  'coverAnim': s.coverAnim,
  'coverAnimSeconds': s.coverAnimSeconds,
  'lyricStyle': s.lyricStyle,
};

/// Apply a look (a preset or the Undo snapshot); only the keys it has.
void applyLook(Settings s, Map look) {
  T? get<T>(String k) => look[k] is T ? look[k] as T : null;
  if (get<String>('buttonStyle') case final v?) s.setButtonStyle(v);
  if (get<String>('reduceMotion') case final v?) s.setReduceMotion(v);
  if (get<num>('uiScale') case final v?) s.setUiScale(v.toDouble());
  if (get<String>('nowPlayingLayout') case final v?) s.setNowPlayingLayout(v);
  if (get<bool>('showArtStack') case final v?) s.setShowArtStack(v);
  if (get<num>('bgDim') case final v?) s.setBgDim(v.toDouble());
  if (get<bool>('colorFade') case final v?) s.setColorFade(v);
  if (get<num>('colorFadeSeconds') case final v?) s.setColorFadeSeconds(v.toDouble());
  if (get<num>('lyricScale') case final v?) s.setLyricScale(v.toDouble());
  if (get<num>('plainLyricScale') case final v?) s.setPlainLyricScale(v.toDouble());
  if (get<String>('lyricsForcedSource') case final v?) s.setLyricsSource(v);
  if (get<String>('coverAnim') case final v?) s.setCoverAnim(v);
  if (get<num>('coverAnimSeconds') case final v?) s.setCoverAnimSeconds(v.toDouble());
  if (get<Map>('lyricStyle') case final v?) {
    s.setLyricStyle({
      for (final MapEntry(:key, :value) in v.entries)
        if (value is num) '$key': value.toDouble(),
    });
  }
}

class StyleMenu extends StatefulWidget {
  const StyleMenu({super.key, required this.tab, required this.live, required this.onClose, this.onTab, this.showClose = true});
  final String tab;

  /// A song is playing beside it: the look controls are on.
  final bool live;
  final VoidCallback onClose;
  final ValueChanged<String>? onTab;

  /// Now Playing has its own close button in the art column.
  final bool showClose;

  @override
  State<StyleMenu> createState() => _StyleMenuState();
}

class _StyleMenuState extends State<StyleMenu> {
  late String _tab = widget.tab;
  late final _Snapshot _opened = _Snapshot(PlayerScope.read(context).settings);

  @override
  void didUpdateWidget(StyleMenu old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) _tab = widget.tab;
  }

  void _go(String t) {
    setState(() => _tab = t);
    widget.onTab?.call(t);
  }

  @override
  Widget build(BuildContext context) {
    final s = PlayerScope.of(context).settings;
    final changed = jsonEncode(_lookOf(s)) != _opened.json;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Center(
                    // Shrinks rather than scrolls when the menu is narrow.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: PillTabs(tabs: styleTabs, value: _tab, small: true, onChanged: _go),
                    ),
                  ),
                ),
                if (widget.showClose) IconBtn(Icons.close_rounded, 'Close', widget.onClose),
              ],
            ),
          ),
          if (!widget.live)
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 26, 8),
              child: Text('Play something to change how it looks: the lyrics and Now Playing need a song to show the change.', style: ts(12, c: K.text3)),
            ),
          Expanded(
            child: SlidingPanes(
              index: styleTabs.indexWhere((t) => t.$1 == _tab),
              vertical: true,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(26, 6, 26, 26),
                children: [
                  ...switch (_tab) {
                    'appearance' => _appearance(s),
                    'nowplaying' => _nowPlaying(s),
                    'lyrics' => _lyrics(s),
                    'crossfade' => _crossfade(s),
                    _ => _presets(s),
                  },
                  const SizedBox(height: 12),
                  Center(
                    child: Hover(
                      onTap: () => _reset(s),
                      builder: (_, on) => Text(
                        'Reset this tab',
                        style: ts(12, w: FontWeight.w500, c: on ? K.text : K.text2).copyWith(decoration: TextDecoration.underline, decorationColor: K.text3),
                      ),
                    ),
                  ),
                  if (changed) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: Pill(
                        'Undo changes since opening',
                        primary: false,
                        onTap: () {
                          applyLook(s, jsonDecode(_opened.json) as Map);
                          s.setLyricStyle(_opened.lyricStyle);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: ts(15, w: FontWeight.w600, ls: -0.15)),
        const SizedBox(height: 4),
        ...rows,
      ],
    ),
  );

  // Rows here are frameless, 9px apart, controls 196 wide (the editor's look).
  Widget _row(String title, Widget trailing, {String? subtitle, bool visual = true}) => Opacity(
    opacity: visual && !widget.live ? 0.45 : 1,
    child: IgnorePointer(
      ignoring: visual && !widget.live,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ts(13, w: FontWeight.w500)),
                  if (subtitle != null) Text(subtitle, style: ts(11.5, c: K.text3, h: 1.35)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            trailing,
          ],
        ),
      ),
    ),
  );

  Widget _slider(double value, double min, double max, double step, String label, ValueChanged<double> onChanged, {VoidCallback? onReset}) => SizedBox(
    width: 196 + 22,
    child: Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: const SliderThemeData(
              trackHeight: 3,
              activeTrackColor: K.accent,
              inactiveTrackColor: K.line,
              thumbColor: K.text,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: ((max - min) / step).round().clamp(1, 2000), onChanged: onChanged),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: ts(11, c: K.text3),
          ),
        ),
        SizedBox(width: 22, child: onReset == null ? null : IconBtn(Icons.restart_alt_rounded, 'Back to the shipped value', onReset, size: 14)),
      ],
    ),
  );

  Widget _menu<T>(T value, Map<T, String> items, ValueChanged<T> onChanged) => Container(
    width: 196,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: K.surface,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: K.line),
    ),
    child: DropdownButton<T>(
      value: items.containsKey(value) ? value : items.keys.first,
      isExpanded: true,
      isDense: true,
      underline: const SizedBox.shrink(),
      dropdownColor: K.surface2,
      style: ts(12),
      padding: const EdgeInsets.symmetric(vertical: 6),
      items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => v == null ? null : onChanged(v),
    ),
  );

  String _pct(double v) => '${(v * 100).round()}%';

  List<Widget> _appearance(Settings s) => [
    _section('Interface', [
      _row(
        'Interface size',
        _slider(s.uiScale, 0.8, 1.5, 0.05, _pct(s.uiScale), s.setUiScale, onReset: s.uiScale == 1 ? null : () => s.setUiScale(1)),
        subtitle: 'Everything, bigger or smaller. Ctrl + and Ctrl - too.',
        visual: false,
      ),
      _row(
        'Buttons',
        Segmented<String>(value: s.buttonStyle, items: const {'overlay': 'Overlay', 'push': 'Push', 'labeled': 'Labeled'}, onChanged: s.setButtonStyle),
        subtitle: 'How page buttons show their names: over their neighbors, making room, or always',
        visual: false,
      ),
      _row(
        'Reduce motion',
        Segmented<String>(value: s.reduceMotion, items: const {'auto': 'Auto', 'on': 'On', 'off': 'Off'}, onChanged: s.setReduceMotion),
        subtitle: 'Fades instead of slides, swipes and springs. Auto follows your system setting.',
        visual: false,
      ),
    ]),
  ];

  List<Widget> _nowPlaying(Settings s) => [
    _section('Layout', [
      _row(
        'Layout',
        _menu<String>(s.nowPlayingLayout, const {'bar': 'Player bar stays', 'under': 'Controls under the art', 'focus': 'Focus'}, s.setNowPlayingLayout),
        subtitle: 'Where the controls go while Now Playing is open',
      ),
      _row(
        "Show what's next behind the art",
        Toggle(value: s.showArtStack, onChanged: s.setShowArtStack),
        subtitle: 'The queue\'s next songs stepped behind the cover',
      ),
    ]),
    _section('Background', [_row('Background dim', _slider(s.bgDim, 0, 1, 0.01, _pct(s.bgDim), s.setBgDim))]),
    _section('Between songs', [
      _row('Fade background colors between songs', Toggle(value: s.colorFade, onChanged: s.setColorFade)),
      if (s.colorFade) _row('Fade on skip', _slider(s.colorFadeSeconds, 0.2, 2, 0.1, '${s.colorFadeSeconds.toStringAsFixed(1)} s', s.setColorFadeSeconds)),
    ]),
  ];

  List<Widget> _lyrics(Settings s) {
    final json = tuningJson;
    final tuning = json == null ? null : LyricStyleTuning(TuningDefaults(json, platform: narrow(context) ? 'ios' : 'desktop'));
    final style = tuning?.lyricStyleFrom(s.lyricStyle) ?? const <String, double>{};
    void set(String key, double v) => s.setLyricStyle(tuning!.lyricStyleChanges({...style, key: v}));
    final sections = <String, List<LyricKnob>>{};
    for (final k in tuning?.knobs ?? const <LyricKnob>[]) {
      if (lyricKnobsUsed.contains(k.key)) sections.putIfAbsent(k.section, () => []).add(k);
    }
    return [
      _section('Source', [
        _row(
          'Lyrics source',
          _menu<String>(s.lyricsSource, {'auto': 'Best available', for (final x in lyricSources) x: x}, s.setLyricsSource),
          subtitle: 'Best available tries SpicyLyrics through Cascade Server first, then Kugou, LRCLIB and your server',
          visual: false,
        ),
      ]),
      _section('Size', [
        _row(
          'Text size',
          _slider(s.lyricScale, 0.8, 1.4, 0.05, _pct(s.lyricScale), s.setLyricScale, onReset: s.lyricScale == 1 ? null : () => s.setLyricScale(1)),
        ),
        _row(
          'Plain lyrics size',
          _slider(
            s.plainLyricScale,
            0.3,
            1.4,
            0.05,
            _pct(s.plainLyricScale),
            s.setPlainLyricScale,
            onReset: s.plainLyricScale == 0.55 ? null : () => s.setPlainLyricScale(0.55),
          ),
        ),
      ]),
      for (final MapEntry(key: name, value: knobs) in sections.entries)
        _section(name, [
          for (final k in knobs)
            _row(
              k.label,
              _slider(
                style[k.key]!,
                k.min,
                k.max,
                k.step,
                '${style[k.key]!.toStringAsFixed(k.step < 0.1 ? 2 : 1)}${k.unit == 'px'
                    ? 'px'
                    : k.unit == 's'
                    ? 's'
                    : ''}',
                (v) => set(k.key, v),
                onReset: (style[k.key]! - k.value).abs() > 1e-9 ? () => set(k.key, k.value) : null,
              ),
            ),
        ]),
    ];
  }

  List<Widget> _crossfade(Settings s) => [
    _section('Crossfade', [
      _row(
        'Crossfade length',
        Text(s.crossfadeEnabled ? '${s.crossfadeSeconds} s' : 'Off', style: ts(12, c: K.text2)),
        subtitle: 'Change in Settings > Playback',
        visual: false,
      ),
    ]),
    _section('Cover animation', [
      _row(
        'Style',
        _menu<String>(s.coverAnim, const {'swipe': 'Toss', 'push': 'Push', 'fade': 'Fade', 'none': 'None'}, s.setCoverAnim),
        subtitle: 'How the cover changes to the next song',
      ),
      if (s.coverAnim != 'none') _row('Length', _slider(s.coverAnimSeconds, 0.2, 2, 0.02, '${s.coverAnimSeconds.toStringAsFixed(2)} s', s.setCoverAnimSeconds)),
    ]),
  ];

  List<Widget> _presets(Settings s) => [
    _section('Share a look', [
      Text('Copy your look as text to share it, or paste one in. It covers the Style menu\'s settings.', style: ts(12, c: K.text2, h: 1.4)),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Pill(
            'Copy as text',
            icon: Icons.copy_rounded,
            primary: false,
            onTap: () {
              Clipboard.setData(ClipboardData(text: jsonEncode({'cascadeLook': 1, ..._lookOf(s)})));
              toast(context, 'Copied your look.');
            },
          ),
          Pill(
            'Paste text',
            icon: Icons.paste_rounded,
            primary: false,
            onTap: () async {
              final t = (await Clipboard.getData('text/plain'))?.text ?? '';
              try {
                final m = jsonDecode(t);
                if (m is! Map || m['cascadeLook'] == null) throw const FormatException();
                applyLook(s, m);
                if (mounted) toast(context, 'Look applied.');
              } catch (_) {
                if (mounted) toast(context, 'That is not a Cascade look.', error: true);
              }
            },
          ),
        ],
      ),
    ]),
  ];

  void _reset(Settings s) {
    switch (_tab) {
      case 'appearance':
        applyLook(s, {'uiScale': 1, 'buttonStyle': 'overlay', 'reduceMotion': 'auto'});
      case 'nowplaying':
        applyLook(s, {'nowPlayingLayout': 'bar', 'showArtStack': true, 'bgDim': 0.62, 'colorFade': true, 'colorFadeSeconds': 0.7});
      case 'lyrics':
        s.setLyricStyle({});
        applyLook(s, {'lyricScale': 1, 'plainLyricScale': 0.55, 'lyricsForcedSource': 'auto'});
      case 'crossfade':
        applyLook(s, {'coverAnim': 'swipe', 'coverAnimSeconds': 0.46});
    }
  }
}
