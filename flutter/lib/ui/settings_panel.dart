// Settings with Electron's six tabs: Library, Playback, Lyrics, Integrations,
// Account and About. A page in the main window on desktop (a tab list down
// the left), the Settings tab on phones (chips across the top).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/electron_import.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/lyrics_fetch.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

const _tabs = [
  ('library', 'Library', Icons.library_music_outlined),
  ('playback', 'Playback', Icons.play_circle_outline_rounded),
  ('lyrics', 'Lyrics', Icons.lyrics_outlined),
  ('integrations', 'Integrations', Icons.extension_outlined),
  ('account', 'Account', Icons.person_outline_rounded),
  ('about', 'About', Icons.info_outline_rounded),
];

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, this.initial = 'library'});
  final String initial;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late String _tab = widget.initial;

  @override
  Widget build(BuildContext context) {
    // Tablets too: the tab column only fits beside the rows on a wide window.
    final small = MediaQuery.sizeOf(context).width < 840;
    final s = PlayerScope.of(context).settings;
    final body = ListenableBuilder(
      listenable: s,
      builder: (context, _) => ListView(
        padding: small ? const EdgeInsets.fromLTRB(16, 4, 16, 40) : const EdgeInsets.fromLTRB(8, 0, 32, 40),
        children: switch (_tab) {
          'library' => _library(context),
          'playback' => _playback(context),
          'lyrics' => _lyrics(context),
          'integrations' => _integrations(context),
          'account' => _account(context),
          _ => _about(context),
        },
      ),
    );
    if (small) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text('Settings', style: Txt.title()),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final (id, label, _) in _tabs)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip_(label, on: _tab == id, onTap: () => setState(() => _tab = id)),
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 30, 0, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Settings', style: Txt.hero()),
                const SizedBox(height: 22),
                for (final (id, label, icon) in _tabs)
                  Hover(
                    onTap: () => setState(() => _tab = id),
                    builder: (_, on) => Container(
                      height: 36,
                      margin: const EdgeInsets.only(bottom: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: _tab == id
                            ? K.accentTint
                            : on
                            ? K.line
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(icon, size: 17, color: _tab == id ? K.accent : K.text2),
                          const SizedBox(width: 10),
                          Text(
                            label,
                            style: ts(13, w: FontWeight.w500, c: _tab == id ? K.text : K.text2),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: body),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _library(BuildContext context) {
    final lib = LibraryScope.of(context), s = PlayerScope.read(context).settings;
    final music = lib.jf?.libraryIds ?? const <String>[];
    return [
      const _Header('Library', top: 8),
      if (lib.demo) Text('Sign in to choose libraries.', style: ts(13, c: K.text3)),
      if (lib.musicLibs.isNotEmpty) ...[
        _Row(title: 'Music libraries', subtitle: 'Albums, artists and songs come from these', trailing: const SizedBox.shrink()),
        for (final l in lib.musicLibs)
          _Check(l['Name'] as String? ?? '', music.contains(l['Id']), (on) {
            final ids = {...music};
            on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
            if (ids.isEmpty) return toast(context, 'Keep at least one music library.');
            lib.setLibraries(music: ids.toList());
          }),
      ],
      if (lib.movieLibs.isNotEmpty || lib.showLibs.isNotEmpty) ...[
        _Row(title: 'Movie and TV libraries', subtitle: 'None chosen hides Movies and TV Shows', trailing: const SizedBox.shrink()),
        for (final l in lib.movieLibs)
          _Check('${l['Name']} (movies)', lib.movieIds.contains(l['Id']), (on) {
            final ids = {...lib.movieIds};
            on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
            lib.setLibraries(movies: ids.toList());
          }),
        for (final l in lib.showLibs)
          _Check('${l['Name']} (shows)', lib.showIds.contains(l['Id']), (on) {
            final ids = {...lib.showIds};
            on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
            lib.setLibraries(shows: ids.toList());
          }),
      ],
      _Switch(
        'Show Live TV as Radio',
        lib.hasLiveTv ? 'Your server\'s channels, in a Radio view' : 'Your server has no Live TV channels',
        s.radioEnabled,
        s.setRadioEnabled,
      ),
      if (lib.isAdmin)
        _Row(
          title: 'Scan library on server',
          subtitle: 'Look for new and changed files now',
          trailing: _Btn('Scan', () async {
            try {
              await lib.scanServer();
              if (context.mounted) toast(context, 'The server is scanning.');
            } catch (e) {
              if (context.mounted) toast(context, 'Could not start a scan: $e', error: true);
            }
          }),
        ),
      _Row(title: 'Refresh app', subtitle: 'Load everything from the server again', trailing: _Btn('Refresh', lib.refresh)),
    ];
  }

  List<Widget> _playback(BuildContext context) {
    final lib = LibraryScope.read(context), p = PlayerScope.of(context), s = p.settings;
    return [
      const _Header('Playback', top: 8),
      _Switch(
        'Crossfade',
        s.crossfadeEnabled ? 'Fade each track into the next' : 'Off: a ${gapMaskSecs.round()} s overlap still hides the gap between tracks',
        s.crossfadeEnabled,
        (v) => s.setCrossfade(enabled: v),
      ),
      if (s.crossfadeEnabled)
        _Row(
          title: 'Crossfade length',
          trailing: SizedBox(
            width: 260,
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    value: s.crossfadeSeconds.toDouble(),
                    min: 1,
                    max: 15,
                    divisions: 14,
                    onChanged: (v) => s.setCrossfade(seconds: v.round()),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('${s.crossfadeSeconds} s', style: ts(13, c: K.text2)),
                ),
              ],
            ),
          ),
        ),
      _Row(
        title: 'Streaming quality',
        subtitle: 'Above this, the server converts the file down',
        trailing: _Menu<int>(value: s.maxStreamingBitrate, items: {for (final q in qualitySteps) q.bitrate: q.label}, onChanged: s.setMaxBitrate),
      ),
      _Switch('Volume normalization', 'Evens out loudness with the server\'s measurements', s.normalizationEnabled, (v) => s.setNormalization(enabled: v)),
      if (s.normalizationEnabled)
        _Row(
          title: 'Normalize by',
          subtitle: 'Album keeps the loudness differences within an album',
          trailing: _Menu<String>(
            value: s.normalizationSource,
            items: const {'track': 'Track', 'album': 'Album'},
            onChanged: (v) => s.setNormalization(source: v),
          ),
        ),
      _Switch('Auto-skip intros and credits', 'When the server marks them', s.autoSkipSegments, s.setAutoSkipSegments),
      _Switch('Equalizer', 'For music', s.eqEnabled, s.setEqEnabled),
      if (s.eqEnabled) _Equalizer(s.eqMusic, onChanged: s.setEqProfile),
      _Row(
        title: 'Output device',
        trailing: _Menu<String>(
          value: p.devices.any((d) => d.name == s.outputDeviceId) ? s.outputDeviceId : 'auto',
          items: {
            'auto': 'System default',
            for (final d in p.devices)
              if (d.name != 'auto') d.name: d.description.isEmpty ? d.name : d.description,
          },
          onChanged: s.setOutputDevice,
        ),
      ),
      _Switch('Auto-mix', 'When the queue runs out, keep going with similar songs', s.autoMix, s.setAutoMix),
      _Row(title: 'Sleep timer', subtitle: sleepLabel(p), trailing: const SleepTimerButton()),
      const _Header('Now Playing'),
      _Row(
        title: 'Layout',
        subtitle: 'Where the controls go when Now Playing is open',
        trailing: _Menu<String>(
          value: s.nowPlayingLayout,
          items: const {'bar': 'Player bar stays', 'under': 'Controls under the art', 'focus': 'Focus'},
          onChanged: s.setNowPlayingLayout,
        ),
      ),
      _Switch('Show what\'s next behind the art', 'The queue\'s next songs stepped behind the cover', s.showArtStack, s.setShowArtStack),
      if (!lib.demo) ...[
        const _Header('Testing'),
        _Switch('Do not report playback', 'The server is never told what plays, so history and resume points stay untouched', s.noReports, s.setNoReports),
      ],
    ];
  }

  List<Widget> _lyrics(BuildContext context) {
    final s = PlayerScope.read(context).settings;
    return [
      const _Header('Lyrics', top: 8),
      _Row(
        title: 'Lyrics source',
        subtitle: 'Best available tries SpicyLyrics through Cascade Server first, then Kugou, LRCLIB and your server',
        trailing: _Menu<String>(value: s.lyricsSource, items: {'auto': 'Best available', for (final x in lyricSources) x: x}, onChanged: s.setLyricsSource),
      ),
    ];
  }

  List<Widget> _integrations(BuildContext context) {
    final s = PlayerScope.read(context).settings;
    return [
      const _Header('Integrations', top: 8),
      _Switch('Discord Rich Presence', 'Show what you are listening to on Discord', s.discordRpc, s.setDiscordRpc),
    ];
  }

  List<Widget> _account(BuildContext context) {
    final lib = LibraryScope.of(context), p = PlayerScope.read(context);
    final code = TextEditingController();
    return [
      const _Header('Account', top: 8),
      _Row(title: 'Server', subtitle: lib.demo ? 'The demo' : lib.jf?.server, trailing: const SizedBox.shrink()),
      _Row(
        title: lib.demo ? 'You are looking at the demo' : 'Signed in as ${lib.jf?.userName ?? '?'}',
        subtitle: lib.isAdmin ? 'Administrator' : null,
        trailing: _Btn(lib.demo ? 'Leave the demo' : 'Sign out', () async {
          await p.stop();
          await lib.signOut();
        }),
      ),
      if (!lib.demo) ...[
        const _Header('Quick Connect'),
        _Row(
          title: 'Approve a device',
          subtitle: 'Type the code another device shows to sign it in as you',
          trailing: SizedBox(
            width: 220,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: code,
                    style: ts(13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Code',
                      hintStyle: ts(13, c: K.text3),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _Btn('Approve', () async {
                  try {
                    await lib.approveQuickConnect(code.text);
                    if (context.mounted) toast(context, 'Approved.');
                  } catch (e) {
                    if (context.mounted) toast(context, 'Could not approve it: $e', error: true);
                  }
                }),
              ],
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _about(BuildContext context) => [
    const _Header('About', top: 8),
    _Row(title: 'Cascade for Windows, Linux and Android', subtitle: 'Version $appVersion', trailing: const SizedBox.shrink()),
    _Row(title: 'Website', subtitle: 'cascade.chaosinc.xyz', trailing: const SizedBox.shrink()),
    _Row(title: 'Fonts', subtitle: 'Hanken Grotesk and Inter, under the SIL Open Font License', trailing: const SizedBox.shrink()),
    _Row(
      title: 'Log',
      subtitle: 'What playback and the server have been doing, for reporting a problem',
      trailing: _Btn(
        'Show',
        () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: K.panel,
            title: Text('Log', style: Txt.section()),
            content: SizedBox(
              width: 720,
              height: 460,
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(recentLog.isEmpty ? 'Nothing logged yet.' : recentLog.join('\n'), style: ts(11, c: K.text2, h: 1.4)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: recentLog.join('\n'))),
                child: const Text('Copy'),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            ],
          ),
        ),
      ),
    ),
    if (electronConfigFile() case final f?)
      _Row(
        title: 'Import from the desktop app',
        subtitle: 'Bring over the Cascade desktop app\'s settings (not its sign-in)',
        trailing: _Btn('Import', () async {
          try {
            final n = await importElectronSettings(f);
            if (context.mounted) toast(context, 'Brought over $n settings. Restart Cascade to use them.');
          } catch (e) {
            if (context.mounted) toast(context, 'Could not read the desktop app\'s settings: $e', error: true);
          }
        }),
      ),
  ];
}

class _Check extends StatelessWidget {
  const _Check(this.label, this.on, this.onChanged);
  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    value: on,
    onChanged: (v) => onChanged(v ?? false),
    dense: true,
    contentPadding: const EdgeInsets.only(left: 12),
    controlAffinity: ListTileControlAffinity.leading,
    activeColor: K.accent,
    checkColor: K.ink,
    title: Text(label, style: ts(13)),
  );
}

class _Btn extends StatelessWidget {
  const _Btn(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pill(label, onTap: onTap, primary: false);
}

String? sleepLabel(Player p) {
  if (p.sleepAtTrackEnd) return 'Pausing at the end of this track';
  final at = p.sleepAt;
  if (at == null) return null;
  final left = at.difference(DateTime.now()).inMinutes + 1;
  return 'Pausing in about $left min';
}

/// The moon: a menu of sleep timer lengths. Lit while one is set.
class SleepTimerButton extends StatelessWidget {
  const SleepTimerButton({super.key});

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final on = p.sleepAt != null || p.sleepAtTrackEnd;
    return PopupMenuButton<int>(
      tooltip: 'Sleep timer',
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap, minimumSize: WidgetStatePropertyAll(Size(30, 30))),
      icon: Icon(on ? Icons.bedtime_rounded : Icons.bedtime_outlined, size: 18, color: on ? K.accent : K.text2),
      onSelected: (m) => switch (m) {
        0 => p.setSleepTimer(null),
        -1 => p.setSleepTimer(null, atTrackEnd: true),
        _ => p.setSleepTimer(Duration(minutes: m)),
      },
      itemBuilder: (_) => [
        for (final m in [15, 30, 45, 60, 90]) PopupMenuItem(value: m, child: Text('$m minutes')),
        const PopupMenuItem(value: -1, child: Text('End of this track')),
        if (on) const PopupMenuItem(value: 0, child: Text('Turn off')),
      ],
    );
  }
}

class _Equalizer extends StatelessWidget {
  const _Equalizer(this.profile, {required this.onChanged});
  final EqProfile profile;
  final void Function(EqProfile) onChanged;

  @override
  Widget build(BuildContext context) {
    final preset = eqPresets.entries.where((e) => _same(e.value, profile.bands)).firstOrNull?.key;
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Column(
        children: [
          _Row(
            title: 'Preset',
            trailing: _Menu<String>(
              value: preset ?? 'Custom',
              items: {for (final k in eqPresets.keys) k: k, if (preset == null) 'Custom': 'Custom'},
              onChanged: (k) {
                final bands = eqPresets[k];
                if (bands != null) onChanged((enabled: profile.enabled, preamp: profile.preamp, bands: [...bands]));
              },
            ),
          ),
          for (var i = 0; i < eqBands.length; i++)
            Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(eqBands[i] >= 1000 ? '${eqBands[i] ~/ 1000} kHz' : '${eqBands[i]} Hz', style: ts(12, c: K.text2)),
                ),
                Expanded(
                  child: Slider(
                    value: profile.bands[i],
                    min: -eqGainLimit,
                    max: eqGainLimit,
                    divisions: 48,
                    onChanged: (v) => onChanged((enabled: profile.enabled, preamp: profile.preamp, bands: [...profile.bands]..[i] = v)),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text('${profile.bands[i] > 0 ? '+' : ''}${profile.bands[i].toStringAsFixed(1)}', style: ts(12, c: K.text2)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static bool _same(List<double> a, List<double> b) => [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.top = 28});
  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 8),
    child: Text(text.toUpperCase(), style: Txt.caps()),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, required this.trailing});
  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ts(14, w: FontWeight.w500)),
              if (subtitle != null) Text(subtitle!, style: ts(12, c: K.text3)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        trailing,
      ],
    ),
  );
}

class _Switch extends StatelessWidget {
  const _Switch(this.title, this.subtitle, this.value, this.onChanged);
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Row(
    title: title,
    subtitle: subtitle,
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

class _Menu<T> extends StatelessWidget {
  const _Menu({required this.value, required this.items, required this.onChanged});
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButton<T>(
    value: items.containsKey(value) ? value : items.keys.first,
    underline: const SizedBox.shrink(),
    borderRadius: BorderRadius.circular(10),
    dropdownColor: K.surface2,
    style: ts(13),
    items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );
}
