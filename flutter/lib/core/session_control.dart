// Driving OTHER Jellyfin sessions from Cascade (Spotify Connect style device
// picking): which sessions are real targets, and the request shapes for the
// device panel's commands. Pure. Ported from desktop/src/core/session-control.ts.
// A session is the Map Jellyfin returns (Id, DeviceId, SupportsRemoteControl,
// NowPlayingItem, PlayState...).
import 'dart:math';

typedef RemoteSession = Map<String, dynamic>;

/// Sessions Cascade can drive: remote-controllable and not our own device (a null DeviceId is not us).
List<RemoteSession> filterControllableSessions(List<RemoteSession> sessions, String ownDeviceId) =>
    sessions.where((s) => s['SupportsRemoteControl'] == true && s['DeviceId'] != ownDeviceId).toList();

const _ticksPerSec = 10000000;

/// Seconds to ticks. NaN, negative or infinite gives 0, so a corrupted seek target never reaches the server.
int secondsToTicks(num sec) => sec.isFinite && sec > 0 ? (sec * _ticksPerSec).round() : 0;

/// Jellyfin's 0-100 volume scale, rounded. Anything not finite is 0.
int clampVolumePercent(Object? n) => n is num && n.isFinite ? n.round().clamp(0, 100) : 0;

/// Query params for `POST /Sessions/{id}/Playing`, or null when there is nothing to play.
({String playCommand, List<String> itemIds, int startIndex})? buildPlayOnDeviceParams(List<String> itemIds, {String playCommand = 'PlayNow', int startIndex = 0}) {
  final ids = itemIds.where((s) => s.isNotEmpty).toList();
  if (ids.isEmpty) return null;
  return (playCommand: playCommand, itemIds: ids, startIndex: max(0, startIndex));
}

/// Body for `POST /Sessions/{id}/Command` (the route that can carry a volume value).
Map<String, Object> buildSetVolumeCommand(num percent) => {
      'Name': 'SetVolume',
      'Arguments': {'Volume': '${clampVolumePercent(percent)}'},
    };

/// A polled position projected forward from the last poll so a progress bar does not freeze between polls. Linear; holds still while paused. 0 with no play state.
// ponytail: no correction for the target's playback rate or a buffering stall.
double interpolatedPositionTicks(Map<String, dynamic>? playState, int polledAtMs, int nowMs) {
  final base = playState?['PositionTicks'];
  if (base is! num || !base.isFinite) return 0;
  if (playState?['IsPaused'] == true) return base.toDouble();
  final elapsedMs = max(0, nowMs - polledAtMs);
  return base + elapsedMs * (_ticksPerSec / 1000);
}
