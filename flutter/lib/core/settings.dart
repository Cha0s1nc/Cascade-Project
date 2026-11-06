// Settings, stored under electron-store's key names so importing the
// desktop's config.json is a straight mapping. Each setter is the one path
// that changes its value, as on the desktop.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/playback.dart';

class Settings extends ChangeNotifier {
  Settings._(this._p);

  /// Loaded once at startup; tests use [Settings.memory].
  static Future<Settings> load() async => Settings._(await SharedPreferences.getInstance());

  final SharedPreferences? _p;

  /// Defaults only, nothing saved: for tests and the demo.
  Settings.memory() : _p = null;

  // Crossfade: off on the desktop by default, 6 s when turned on (1-15).
  late bool crossfadeEnabled = _p?.getBool('crossfadeEnabled') ?? false;
  late int crossfadeSeconds = (_p?.getInt('crossfadeSeconds') ?? 6).clamp(1, 15);

  late int maxStreamingBitrate = _p?.getInt('maxStreamingBitrate') ?? defaultMaxBitrate;

  late bool normalizationEnabled = _p?.getBool('normalizationEnabled') ?? false;

  /// 'track' or 'album'.
  late String normalizationSource = _p?.getString('normalizationSource') == 'album' ? 'album' : 'track';

  late bool eqEnabled = _p?.getBool('eqEnabled') ?? false;
  late EqProfile eqMusic = _profile('eqMusic');
  late EqProfile eqVideo = _profile('eqVideo');

  /// mpv's name for the output device; 'auto' follows the system default.
  late String outputDeviceId = _p?.getString('outputDeviceId') ?? 'auto';

  late double volume = (_p?.getDouble('volume') ?? 0.7).clamp(0, 1);
  late String repeatMode = _p?.getString('repeatMode') ?? 'none';
  late bool shuffle = _p?.getBool('shuffle') ?? false;
  late bool autoMix = _p?.getBool('autoMixEnabled') ?? false;

  /// Show the server's Live TV channels as Radio (off, as on the desktop).
  late bool radioEnabled = _p?.getBool('radioEnabled') ?? false;

  /// Never tell the server what plays, for test runs against a real server
  /// (like the Swift app's -cascade.noReports). Also CASCADE_NO_REPORTS=1.
  late bool noReports = (_p?.getBool('noReports') ?? false) || Platform.environment['CASCADE_NO_REPORTS'] == '1';

  EqProfile _profile(String key) {
    try {
      return normalizeProfile(jsonDecode(_p?.getString(key) ?? 'null'));
    } catch (_) {
      return normalizeProfile(null);
    }
  }

  /// Called with the save in flight, which is never awaited.
  void _changed(Object? _) => notifyListeners();

  void setCrossfade({bool? enabled, int? seconds}) {
    if (enabled != null) _p?.setBool('crossfadeEnabled', crossfadeEnabled = enabled);
    if (seconds != null) _p?.setInt('crossfadeSeconds', crossfadeSeconds = seconds.clamp(1, 15));
    _changed(null);
  }

  void setMaxBitrate(int bitrate) => _changed(_p?.setInt('maxStreamingBitrate', maxStreamingBitrate = bitrate));

  void setNormalization({bool? enabled, String? source}) {
    if (enabled != null) _p?.setBool('normalizationEnabled', normalizationEnabled = enabled);
    if (source != null) _p?.setString('normalizationSource', normalizationSource = source == 'album' ? 'album' : 'track');
    _changed(null);
  }

  void setEqEnabled(bool on) => _changed(_p?.setBool('eqEnabled', eqEnabled = on));

  void setEqProfile(EqProfile p, {bool video = false}) {
    if (video) {
      eqVideo = p;
    } else {
      eqMusic = p;
    }
    _changed(_p?.setString(video ? 'eqVideo' : 'eqMusic', jsonEncode(profileJson(p))));
  }

  void setOutputDevice(String id) => _changed(_p?.setString('outputDeviceId', outputDeviceId = id));

  /// Saved quietly: these change constantly while playing.
  void remember({double? volume, String? repeatMode, bool? shuffle}) {
    if (volume != null) _p?.setDouble('volume', this.volume = volume);
    if (repeatMode != null) _p?.setString('repeatMode', this.repeatMode = repeatMode);
    if (shuffle != null) _p?.setBool('shuffle', this.shuffle = shuffle);
  }

  void setAutoMix(bool on) => _changed(_p?.setBool('autoMixEnabled', autoMix = on));

  void setRadioEnabled(bool on) => _changed(_p?.setBool('radioEnabled', radioEnabled = on));

  void setNoReports(bool on) => _changed(_p?.setBool('noReports', noReports = on));

  /// The lyrics source to use: 'auto' or one of lyricSources (desktop's key).
  late String lyricsSource = _p?.getString('lyricsForcedSource') ?? 'auto';
  void setLyricsSource(String v) => _changed(_p?.setString('lyricsForcedSource', lyricsSource = v));

  /// Discord Rich Presence (desktop's discordRpcEnabled), off by default as there.
  late bool discordRpc = _p?.getBool('discordRpcEnabled') ?? false;
  void setDiscordRpc(bool on) => _changed(_p?.setBool('discordRpcEnabled', discordRpc = on));

  /// Skip intros and credits by themselves (media segments).
  late bool autoSkipSegments = _p?.getBool('autoSkipSegments') ?? false;
  void setAutoSkipSegments(bool on) => _changed(_p?.setBool('autoSkipSegments', autoSkipSegments = on));

  /// The lyric style knobs this person changed (the desktop's lyricStyle:
  /// only changes are stored; defaults come from tuning-defaults.json).
  late Map<String, double> lyricStyle = () {
    try {
      final m = jsonDecode(_p?.getString('lyricStyle') ?? '{}');
      return {
        for (final MapEntry(:key, :value) in (m as Map).entries)
          if (value is num) '$key': value.toDouble(),
      };
    } catch (_) {
      return <String, double>{};
    }
  }();

  void setLyricStyle(Map<String, double> changes) {
    lyricStyle = changes;
    _changed(_p?.setString('lyricStyle', jsonEncode(changes)));
  }

  // The Style menu ---------------------------------------------------------

  double _num(String k, double d, double lo, double hi) => (_p?.getDouble(k) ?? d).clamp(lo, hi);

  /// How page buttons open their labels: 'overlay' (over their neighbors,
  /// Electron's default), 'push' (the row makes room) or 'labeled' (always).
  late String buttonStyle = switch (_p?.getString('buttonStyle')) {
    'push' => 'push',
    'labeled' => 'labeled',
    _ => 'overlay',
  };
  void setButtonStyle(String v) => _changed(_p?.setString('buttonStyle', buttonStyle = v));

  /// The desktop sidebar: 'expanded', 'hover' (a rail that slides out under
  /// the mouse, as the Electron app's) or 'rail' (icons only).
  late String sidebarMode = switch (_p?.getString('sidebarMode')) {
    'hover' => 'hover',
    'rail' => 'rail',
    _ => 'expanded',
  };
  void setSidebarMode(String v) => _changed(_p?.setString('sidebarMode', sidebarMode = v));

  /// The whole interface's size, 0.8 to 1.5 (Ctrl + and - too).
  late double uiScale = _num('uiScale', 1, 0.8, 1.5);
  void setUiScale(double v) => _changed(_p?.setDouble('uiScale', uiScale = (v * 20).round() / 20));

  /// Lyric text size and plain (untimed) lyrics size (npTuning on the desktop).
  late double lyricScale = _num('lyricScale', 1, 0.8, 1.4);
  void setLyricScale(double v) => _changed(_p?.setDouble('lyricScale', lyricScale = v));
  late double plainLyricScale = _num('plainLyricScale', 0.55, 0.3, 1.4);
  void setPlainLyricScale(double v) => _changed(_p?.setDouble('plainLyricScale', plainLyricScale = v));

  /// How dark the cover behind Now Playing is (0 to 1).
  late double bgDim = _num('bgDim', 0.62, 0, 1);
  void setBgDim(double v) => _changed(_p?.setDouble('bgDim', bgDim = v));

  /// The cover's change between songs: 'swipe' (flicked off to the side),
  /// 'fade', 'push' or 'none'; how long it takes.
  late String coverAnim = switch (_p?.getString('coverAnim')) {
    'fade' => 'fade',
    'push' => 'push',
    'none' => 'none',
    _ => 'swipe',
  };
  void setCoverAnim(String v) => _changed(_p?.setString('coverAnim', coverAnim = v));
  late double coverAnimSeconds = _num('coverAnimSeconds', 0.6, 0.2, 2);
  void setCoverAnimSeconds(double v) => _changed(_p?.setDouble('coverAnimSeconds', coverAnimSeconds = v));

  /// Background colors fade between songs, over this long on a skip.
  late bool colorFade = _p?.getBool('colorFade') ?? true;
  void setColorFade(bool on) => _changed(_p?.setBool('colorFade', colorFade = on));
  late double colorFadeSeconds = _num('colorFadeSeconds', 0.7, 0.2, 2);
  void setColorFadeSeconds(double v) => _changed(_p?.setDouble('colorFadeSeconds', colorFadeSeconds = v));

  /// Personality v1: the queue's next songs stepped behind the art.
  late bool showArtStack = _p?.getBool('showArtStack') ?? true;
  void setShowArtStack(bool on) => _changed(_p?.setBool('showArtStack', showArtStack = on));

  /// Now Playing layout on desktop: 'bar' (player bar stays), 'under'
  /// (controls under the art) or 'focus'. Same key in every app.
  late String nowPlayingLayout = switch (_p?.getString('nowPlayingLayout')) {
    'under' => 'under',
    'focus' => 'focus',
    _ => 'bar',
  };
  void setNowPlayingLayout(String v) => _changed(_p?.setString('nowPlayingLayout', nowPlayingLayout = v));

  /// Where the saved queue came from, for Home's "Previously queued" card.
  String? get lastQueueSource => _p?.getString('lastQueueSource');
  void saveLastQueueSource(String? s) => s == null ? _p?.remove('lastQueueSource') : _p?.setString('lastQueueSource', s);

  /// The last queue, as the desktop stores it (a JSON string under 'lastQueue').
  Object? get lastQueue {
    try {
      return jsonDecode(_p?.getString('lastQueue') ?? 'null');
    } catch (_) {
      return null;
    }
  }

  void saveLastQueue(Map<String, Object>? q) => q == null ? _p?.remove('lastQueue') : _p?.setString('lastQueue', jsonEncode(q));
}
