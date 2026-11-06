// Settings as the Electron app lays it out: six tabs in a pill track whose
// accent pill slides to the chosen one, panes that slide sideways as tabs
// change, and each tab's settings in grouped cards. The look of Now Playing
// and the lyrics is not here: it is in the Style menu, which the Style
// buttons open.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cascade/core/electron_import.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/core/playback.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/controls.dart';
import 'package:cascade/ui/eq_editor.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/style_menu.dart';
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
    final small = MediaQuery.sizeOf(context).width < 860;
    final s = PlayerScope.of(context).settings;
    final index = _tabs.indexWhere((t) => t.$1 == _tab);
    // Captured: the pane sliding out keeps its own tab even if it rebuilds.
    final tab = _tab;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, small ? 12 : 22, 16, 12),
          // A phone scrolls the tabs; a desktop window shrinks them so none hide.
          child: Builder(
            builder: (context) {
              final tabs = PillTabs(tabs: _tabs, value: _tab, small: small, onChanged: (t) => setState(() => _tab = t));
              return narrow(context) ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: tabs) : FittedBox(fit: BoxFit.scaleDown, child: tabs);
            },
          ),
        ),
        Expanded(
          child: SlidingPanes(
            index: index,
            child: ListenableBuilder(
              listenable: s,
              builder: (context, _) => ListView(
                padding: EdgeInsets.fromLTRB(small ? 16 : 22, 6, small ? 16 : 22, 32),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: switch (tab) {
                          'library' => _library(context),
                          'playback' => _playback(context),
                          'lyrics' => _lyrics(context),
                          'integrations' => _integrations(context),
                          'account' => _account(context),
                          _ => _about(context),
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _library(BuildContext context) {
    final lib = LibraryScope.of(context), s = PlayerScope.read(context).settings;
    final music = lib.jf?.libraryIds ?? const <String>[];
    return [
      if (lib.demo) const SettingsGroup('Libraries', [SettingRow('Sign in to choose libraries')]),
      if (lib.musicLibs.isNotEmpty)
        SettingsGroup('Music', [
          const SettingRow('Music libraries', subtitle: 'Albums, artists and songs come from these. At least one stays on.'),
          for (final l in lib.musicLibs)
            ToggleRow(
              l['Name'] as String? ?? '',
              music.contains(l['Id']),
              // The last one on cannot be turned off.
              music.contains(l['Id']) && music.length == 1
                  ? null
                  : (on) {
                      final ids = {...music};
                      on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
                      lib.setLibraries(music: ids.toList());
                    },
              indent: 12,
            ),
        ]),
      if (lib.movieLibs.isNotEmpty || lib.showLibs.isNotEmpty)
        SettingsGroup('Movies and TV', [
          const SettingRow('Video libraries', subtitle: 'None on hides Movies and TV Shows'),
          for (final l in lib.movieLibs)
            ToggleRow(
              '${l['Name']}',
              lib.movieIds.contains(l['Id']),
              (on) {
                final ids = {...lib.movieIds};
                on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
                lib.setLibraries(movies: ids.toList());
              },
              subtitle: 'Movies',
              indent: 12,
            ),
          for (final l in lib.showLibs)
            ToggleRow(
              '${l['Name']}',
              lib.showIds.contains(l['Id']),
              (on) {
                final ids = {...lib.showIds};
                on ? ids.add(l['Id'] as String) : ids.remove(l['Id']);
                lib.setLibraries(shows: ids.toList());
              },
              subtitle: 'TV Shows',
              indent: 12,
            ),
        ]),
      if (!lib.demo)
        SettingsGroup('Offline', [
          ToggleRow(
            'Offline Mode',
            lib.offline,
            lib.setOfflineMode,
            subtitle: lib.offlineState.name == 'unreachable'
                ? 'On by itself: your server is not answering, so you are listening to your downloads'
                : 'Only your downloads, and nothing is sent to the server. Plays and likes are sent when you turn it off.',
          ),
        ]),
      SettingsGroup('Server', [
        ToggleRow(
          'Show Live TV as Radio',
          s.radioEnabled,
          s.setRadioEnabled,
          subtitle: lib.hasLiveTv ? 'Your server\'s channels, in a Radio view' : 'Your server has no Live TV channels',
        ),
        if (lib.isAdmin)
          SettingRow(
            'Scan library on server',
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
        SettingRow('Refresh app', subtitle: 'Load everything from the server again', trailing: _Btn('Refresh', lib.refresh)),
      ]),
    ];
  }

  List<Widget> _playback(BuildContext context) {
    final lib = LibraryScope.read(context), p = PlayerScope.of(context), s = p.settings;
    final steps = qualitySteps;
    final q = steps.indexWhere((x) => x.bitrate == s.maxStreamingBitrate);
    return [
      SettingsGroup('Playback', [
        SliderRow(
          'Streaming quality',
          subtitle: 'Above this, the server converts the file down',
          value: (q < 0 ? 0 : q).toDouble(),
          min: 0,
          max: (steps.length - 1).toDouble(),
          step: 1,
          label: steps[q < 0 ? 0 : q].label,
          onChanged: (v) => s.setMaxBitrate(steps[v.round()].bitrate),
        ),
        ToggleRow(
          'Volume normalization',
          s.normalizationEnabled,
          (v) => s.setNormalization(enabled: v),
          subtitle: 'Evens out loudness with the server\'s measurements',
        ),
        if (s.normalizationEnabled)
          ChoiceRow<String>(
            'Normalize by',
            subtitle: 'Album keeps the loudness differences within an album',
            value: s.normalizationSource,
            items: const {'track': 'Track', 'album': 'Album'},
            onChanged: (v) => s.setNormalization(source: v),
          ),
        ToggleRow('Auto-skip intros and credits', s.autoSkipSegments, s.setAutoSkipSegments, subtitle: 'When the server marks them'),
        ChoiceRow<String>(
          'Output device',
          value: p.devices.any((d) => d.name == s.outputDeviceId) ? s.outputDeviceId : 'auto',
          items: {
            'auto': 'System default',
            for (final d in p.devices)
              if (d.name != 'auto') d.name: d.description.isEmpty ? d.name : d.description,
          },
          onChanged: s.setOutputDevice,
        ),
        ToggleRow('Auto-mix', s.autoMix, s.setAutoMix, subtitle: 'When the queue runs out, keep going with similar songs'),
        SettingRow('Sleep timer', subtitle: sleepLabel(p) ?? 'Pause after a while, or at the end of the song', trailing: const SleepTimerButton()),
      ]),
      SettingsGroup('Crossfade', [
        ToggleRow(
          'Crossfade',
          s.crossfadeEnabled,
          (v) => s.setCrossfade(enabled: v),
          subtitle: s.crossfadeEnabled ? 'Fade each song into the next' : 'Off: a ${gapMaskSecs.round()} s overlap still hides the gap between songs',
        ),
        if (s.crossfadeEnabled)
          SliderRow(
            'Crossfade length',
            value: s.crossfadeSeconds.toDouble(),
            min: 1,
            max: 15,
            step: 1,
            label: '${s.crossfadeSeconds} s',
            onChanged: (v) => s.setCrossfade(seconds: v.round()),
          ),
      ]),
      SettingsGroup('Equalizer', [
        ToggleRow('Enable equalizer', s.eqEnabled, s.setEqEnabled, subtitle: 'Off leaves every band at 0 dB, so turning this back on never clicks.'),
        EqPanels(s),
      ]),
      const _StyleGroup(),
      if (!lib.demo)
        SettingsGroup('Testing', [
          ToggleRow(
            'Do not report playback',
            s.noReports,
            s.setNoReports,
            subtitle: 'The server is never told what plays, so history and resume points stay untouched',
          ),
        ]),
    ];
  }

  List<Widget> _lyrics(BuildContext context) => const [_StyleGroup(lyrics: true)];

  List<Widget> _integrations(BuildContext context) {
    final s = PlayerScope.read(context).settings;
    return [
      SettingsGroup('Integrations', [ToggleRow('Discord Rich Presence', s.discordRpc, s.setDiscordRpc, subtitle: 'Show what you are listening to on Discord')]),
    ];
  }

  List<Widget> _account(BuildContext context) {
    final lib = LibraryScope.of(context), p = PlayerScope.read(context);
    return [
      SettingsGroup('Account', [
        SettingRow('Server', subtitle: lib.demo ? 'The demo' : lib.jf?.server),
        SettingRow(
          lib.demo ? 'You are looking at the demo' : 'Signed in as ${lib.jf?.userName ?? '?'}',
          subtitle: lib.isAdmin ? 'Administrator' : null,
          trailing: _Btn(lib.demo ? 'Leave the demo' : 'Sign out', () async {
            await p.stop();
            await lib.signOut();
          }),
        ),
      ]),
      if (!lib.demo) SettingsGroup('Quick Connect', [_QuickConnect(lib: lib)]),
    ];
  }

  List<Widget> _about(BuildContext context) => [
    const SettingsGroup('About', [
      SettingRow('Cascade for Windows, Linux and Android', subtitle: 'Version $appVersion'),
      SettingRow('Website', subtitle: 'cascade.chaosinc.xyz'),
      SettingRow('Fonts', subtitle: 'Hanken Grotesk and Inter, under the SIL Open Font License'),
    ]),
    SettingsGroup('Help', [
      SettingRow(
        'Log',
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
        SettingRow(
          'Import from the desktop app',
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
    ]),
  ];
}

/// Where the look settings went: a group that says so and opens Style.
class _StyleGroup extends StatelessWidget {
  const _StyleGroup({this.lyrics = false});
  final bool lyrics;

  @override
  Widget build(BuildContext context) => SettingsGroup(lyrics ? 'Lyrics' : 'Now Playing', [
    SettingRow(
      lyrics ? 'Lyrics source, size and motion' : 'Layout, background and lyrics',
      subtitle: lyrics
          ? 'Where lyrics come from, and how they look and move, are in the Style menu.'
          : 'How Now Playing looks, what is behind the art, and the lyrics are in the Style menu.',
      trailing: Pill(
        'Style',
        icon: Icons.brush_outlined,
        onTap: () => openStyleMenu(context, tab: lyrics ? 'lyrics' : 'nowplaying'),
      ),
    ),
  ]);
}

class _QuickConnect extends StatefulWidget {
  const _QuickConnect({required this.lib});
  final Library lib;

  @override
  State<_QuickConnect> createState() => _QuickConnectState();
}

class _QuickConnectState extends State<_QuickConnect> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingRow(
    'Approve a device',
    subtitle: 'Type the code another device shows to sign it in as you',
    trailing: SizedBox(
      width: 260,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _code,
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
              await widget.lib.approveQuickConnect(_code.text);
              if (context.mounted) toast(context, 'Approved.');
            } catch (e) {
              if (context.mounted) toast(context, 'Could not approve it: $e', error: true);
            }
          }),
        ],
      ),
    ),
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
