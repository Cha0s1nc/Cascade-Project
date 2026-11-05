// Offline Mode's one state, pure so the rules are tested. Ported from
// desktop/src/core/offline-mode.ts.
//
// - online: the server answers.
// - manual: the Settings switch is on. Nothing goes to the server, and it stays
//   on until turned off, whatever the network does.
// - unreachable: the server stopped answering. Probed on a backoff; left by
//   itself when it answers.
// - local: Local mode, no server at all. Offline as far as the screens go, but
//   lyrics, artwork, translation models and update checks still go out.
import 'dart:math';

enum OfflineState { online, manual, unreachable, local }

/// An event that can change the state.
sealed class OfflineEvent {
  const OfflineEvent();
}

/// The Settings switch turned [on] or off.
class OfflineSwitch extends OfflineEvent {
  final bool on;
  const OfflineSwitch(this.on);
}

/// A request or probe found no server.
class OfflineUnreachable extends OfflineEvent {
  const OfflineUnreachable();
}

/// A request or probe was answered.
class OfflineReachable extends OfflineEvent {
  const OfflineReachable();
}

/// The state after an event. A manual switch outranks the network; turning it off goes back online. Local never changes.
OfflineState nextOfflineState(OfflineState state, OfflineEvent event) {
  if (state == OfflineState.local) return state;
  switch (event) {
    case OfflineSwitch(:final on):
      return on ? OfflineState.manual : (state == OfflineState.manual ? OfflineState.online : state);
    case OfflineUnreachable():
      return state == OfflineState.online ? OfflineState.unreachable : state;
    case OfflineReachable():
      return state == OfflineState.unreachable ? OfflineState.online : state;
  }
}

/// Everything but online is offline.
bool isOffline(OfflineState state) => state != OfflineState.online;

/// First probe 30 s after the drop, doubling to five minutes. [attempt] counts from 0.
int probeDelayMs(int attempt) {
  final n = attempt > 0 ? min(attempt, 10) : 0;
  return min(30000 * pow(2, n).toInt(), 300000);
}

/// What a failed request says about the server: 'unreachable' (no answer, or a proxy's 502/503/504), 'auth' (401/403, which asks to sign in again and is never Offline Mode) or 'error' (the request's problem, not the connection's).
String failureKind(int? status) {
  if (status == null || status == 0) return 'unreachable';
  if (status == 401 || status == 403) return 'auth';
  if (status == 502 || status == 503 || status == 504) return 'unreachable';
  return 'error';
}

/// Whether every request to the server's origin is cancelled. Only the manual switch: in the unreachable state the probe has to get through.
bool blocksServer(OfflineState state) => state == OfflineState.manual;

/// Whether requests to other services (LRCLIB, iTunes, MusicBrainz) wait too. Local mode is online as far as the web goes.
bool blocksWeb(OfflineState state) => state == OfflineState.manual || state == OfflineState.unreachable;

/// Update checks wait while offline.
bool checksUpdates(OfflineState state) => state == OfflineState.online || state == OfflineState.local;

/// Whether an update check is due: the app just came back to where checks run.
bool updateCheckDue(OfflineState before, OfflineState after) => !checksUpdates(before) && checksUpdates(after);

/// Parses a state name from outside (IPC, storage), or null.
OfflineState? offlineStateFrom(Object? v) {
  for (final s in OfflineState.values) {
    if (s.name == v) return s;
  }
  return null;
}
