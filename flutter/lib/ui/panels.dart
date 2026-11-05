// The player bar's and title bar's panel buttons: Announcements (the
// project's news from the site, plus the server's through Cascade Server),
// Devices (send what plays to another Jellyfin client and drive it), and
// Waterfall and the Miniplayer, which come later.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/announcements.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/session_control.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

// Announcements ----------------------------------------------------------------

const _announcementsUrl = 'https://announcements.cascade.chaosinc.xyz/announcements.json';
String get _platform => Platform.isAndroid ? 'android' : 'desktop';

/// The inbox: the site's announcements (cached for offline starts) and the
/// server's, minus what was dismissed; unseen counts the new ones.
class AnnouncementStore extends ChangeNotifier {
  List<Announcement> items = const [];
  int unseen = 0;
  bool _loaded = false;

  Future<void> load(Library lib) async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    Object? raw;
    try {
      final res = await http.get(Uri.parse(_announcementsUrl), headers: {'User-Agent': 'cascade'}).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        raw = jsonDecode(res.body);
        await prefs.setString('announcementsCache', res.body);
      }
    } catch (_) {}
    if (raw == null) {
      try {
        raw = jsonDecode(prefs.getString('announcementsCache') ?? 'null');
      } catch (_) {}
    }
    var all = parseAnnouncements(raw, _platform, appVersion);
    final f = lib.lyrics;
    if (f != null) {
      try {
        final p = await f.plugin();
        if (p.caps.contains('announcements')) {
          final s = await lib.jf!.get('/CascadeServer/Announcements');
          all = [...parseServerAnnouncements(s, _platform, appVersion), ...all];
        }
      } catch (_) {}
    }
    all.sort((a, b) => b.date.compareTo(a.date));
    items = all;
    await _refresh(prefs);
  }

  Future<void> _refresh(SharedPreferences prefs) async {
    final inbox = announcementInbox(items, prefs.getStringList('announcementsDismissed'), prefs.getStringList('announcementsSeen'));
    items = inbox.items;
    unseen = inbox.unseen;
    notifyListeners();
  }

  Future<void> _add(String key, Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, {...prefs.getStringList(key) ?? const [], ...ids}.toList());
    await _refresh(prefs);
  }

  Future<void> markSeen() => _add('announcementsSeen', items.map((a) => a.id));
  Future<void> dismiss(String id) => _add('announcementsDismissed', [id]);
}

final announcements = AnnouncementStore();

class AnnouncementsButton extends StatefulWidget {
  const AnnouncementsButton({super.key});

  @override
  State<AnnouncementsButton> createState() => _AnnouncementsButtonState();
}

class _AnnouncementsButtonState extends State<AnnouncementsButton> {
  @override
  void initState() {
    super.initState();
    announcements.load(LibraryScope.read(context)).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: announcements,
    builder: (context, _) => IconBtn(Icons.notifications_none_rounded, 'Announcements', () => _open(context), badge: announcements.unseen > 0),
  );

  void _open(BuildContext context) {
    announcements.markSeen();
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        alignment: Alignment.topRight,
        insetPadding: const EdgeInsets.only(top: 56, right: 16, left: 16, bottom: 16),
        backgroundColor: K.panel,
        child: SizedBox(
          width: 400,
          child: ListenableBuilder(
            listenable: announcements,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Text('Announcements', style: Txt.section()),
                ),
                if (announcements.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Nothing new.', style: ts(13, c: K.text3)),
                  ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: [
                      for (final a in announcements.items)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(a.title, style: ts(14, w: FontWeight.w600)),
                                  ),
                                  IconBtn(Icons.close_rounded, 'Dismiss', () => announcements.dismiss(a.id), size: 15),
                                ],
                              ),
                              Text([a.kind == 'official' ? 'Cascade' : (a.source ?? 'Your server'), a.date].join(' · '), style: ts(11, c: K.text3)),
                              const SizedBox(height: 6),
                              Text(a.body, style: ts(13, c: K.text2, h: 1.45)),
                              if (a.link != null) ...[const SizedBox(height: 6), SelectableText(a.link!, style: ts(12, c: K.accent))],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Devices ----------------------------------------------------------------------

/// Another Jellyfin client this account can drive.
class DevicesButton extends StatelessWidget {
  const DevicesButton({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    return IconBtn(
      Icons.cast_rounded,
      'Connect to a device',
      lib.jf == null
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (_) => _DevicesDialog(lib: lib, outer: context),
            ),
    );
  }
}

class _DevicesDialog extends StatefulWidget {
  const _DevicesDialog({required this.lib, required this.outer});
  final Library lib;
  final BuildContext outer;

  @override
  State<_DevicesDialog> createState() => _DevicesDialogState();
}

class _DevicesDialogState extends State<_DevicesDialog> {
  List<RemoteSession>? _sessions;
  String? _error;
  RemoteSession? _driving;
  Timer? _poll;

  Jellyfin get _jf => widget.lib.jf!;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _jf.get('/Sessions', {'controllableByUserId': _jf.userId});
      final list = filterControllableSessions((r as List).cast<RemoteSession>(), _jf.deviceId);
      if (!mounted) return;
      setState(() {
        _sessions = list;
        if (_driving != null) _driving = list.where((s) => s['Id'] == _driving!['Id']).firstOrNull;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Hand what plays here to [s], from where it is, and pause here.
  Future<void> _send(RemoteSession s) async {
    final p = PlayerScope.read(widget.outer);
    final song = p.song;
    final ids = [if (song != null) song.id, ...p.upNext.map((x) => x.id)];
    final params = buildPlayOnDeviceParams(ids);
    try {
      if (params != null) {
        await _jf.post('/Sessions/${s['Id']}/Playing', null, {
          'playCommand': params.playCommand,
          'itemIds': params.itemIds.join(','),
          'startIndex': params.startIndex,
          'startPositionTicks': secondsToTicks(p.position),
        });
        await p.setPlaying(false);
      }
      setState(() => _driving = s);
    } catch (e) {
      if (mounted) toast(context, 'Could not reach ${s['DeviceName']}: $e', error: true);
    }
  }

  Future<void> _command(String command) => _jf.post('/Sessions/${_driving!['Id']}/Playing/$command').catchError((_) => null);

  @override
  Widget build(BuildContext context) {
    final d = _driving;
    final now = d?['NowPlayingItem'] as Map?;
    final paused = (d?['PlayState'] as Map?)?['IsPaused'] == true;
    final volume = ((d?['PlayState'] as Map?)?['VolumeLevel'] as num? ?? 0).toDouble();
    return AlertDialog(
      backgroundColor: K.panel,
      title: Text(d == null ? 'Connect to a device' : '${d['DeviceName']}', style: Txt.section()),
      content: SizedBox(
        width: 380,
        child: d != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(now == null ? 'Nothing playing there.' : '${now['Name']}', style: ts(15, w: FontWeight.w600)),
                  if (now != null) Text('${now['AlbumArtist'] ?? now['SeriesName'] ?? ''}', style: ts(13, c: K.text2)),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 14,
                    children: [
                      IconBtn(Icons.skip_previous_rounded, 'Previous', () => _command('PreviousTrack'), color: K.text, size: 26),
                      PlayCircle(playing: !paused, onTap: () => _command('PlayPause'), size: 48),
                      IconBtn(Icons.skip_next_rounded, 'Next', () => _command('NextTrack'), color: K.text, size: 26),
                    ],
                  ),
                  ThinBar(
                    value: volume / 100,
                    color: K.text2,
                    onChanged: (v) => _jf.post('/Sessions/${d['Id']}/Command', buildSetVolumeCommand(v * 100)).catchError((_) => null),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _driving = null),
                    child: Text('Other devices', style: ts(13, c: K.accent)),
                  ),
                ],
              )
            : _sessions == null
            ? (_error != null
                  ? Text('Could not list devices: $_error', style: ts(13, c: K.error))
                  : const Center(child: CircularProgressIndicator(strokeWidth: 2.5)))
            : _sessions!.isEmpty
            ? Text('No other Jellyfin apps you can control are open.', style: ts(13, c: K.text2))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in _sessions!)
                    ListTile(
                      leading: const Icon(Icons.devices_rounded, color: K.text2),
                      title: Text('${s['DeviceName']}', style: ts(14, w: FontWeight.w500)),
                      subtitle: Text(
                        '${s['Client']}${s['NowPlayingItem'] != null ? ' · playing ${(s['NowPlayingItem'] as Map)['Name']}' : ''}',
                        style: ts(12, c: K.text3),
                      ),
                      onTap: () => _send(s),
                    ),
                ],
              ),
      ),
    );
  }
}

// Later ------------------------------------------------------------------------

class WaterfallButton extends StatelessWidget {
  const WaterfallButton({super.key});

  @override
  Widget build(BuildContext context) => const IconBtn(Icons.water_drop_outlined, 'Waterfall, listen together (not built yet)', null);
}

class MiniplayerButton extends StatelessWidget {
  const MiniplayerButton({super.key});

  @override
  Widget build(BuildContext context) => const IconBtn(Icons.picture_in_picture_alt_outlined, 'Miniplayer (not built yet)', null);
}
