// Settings, as far as the phases have reached: the account and Playback.
// The same panel in the desktop's Settings view and the phone's tab.
import 'package:flutter/material.dart';

import 'package:cascade/core/playback.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context), p = PlayerScope.of(context), s = p.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
            children: [
              Text('Settings', style: ts(28, w: FontWeight.w700)),
              const _Header('Account'),
              _Row(
                title: lib.demo ? 'You are looking at the demo' : 'Signed in as ${lib.jf?.userName ?? '?'}',
                subtitle: lib.demo ? null : lib.jf?.server,
                trailing: FilledButton.tonal(
                  onPressed: () async {
                    await p.stop();
                    await lib.signOut();
                  },
                  child: Text(lib.demo ? 'Leave the demo' : 'Sign out'),
                ),
              ),
              const _Header('Playback'),
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
              _Switch(
                'Volume normalization',
                'Evens out loudness with the server\'s measurements',
                s.normalizationEnabled,
                (v) => s.setNormalization(enabled: v),
              ),
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
              _Switch(
                'Show Live TV as Radio',
                lib.hasLiveTv ? 'Your server\'s channels, in a Radio view' : 'Your server has no Live TV channels',
                s.radioEnabled,
                s.setRadioEnabled,
              ),
              _Row(title: 'Sleep timer', subtitle: sleepLabel(p), trailing: const SleepTimerButton()),
              _Switch(
                'Do not report playback',
                'For testing: the server is never told what plays, so history and resume points stay untouched',
                s.noReports,
                s.setNoReports,
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: ts(12, w: FontWeight.w600, c: K.text3, ls: 0.6),
    ),
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
