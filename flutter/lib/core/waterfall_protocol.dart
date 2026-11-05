// Waterfall wire format and sync maths. A Waterfall room keeps members in sync
// without audio on the wire: everyone streams the same track from the same
// Jellyfin server and the room carries only "track X, position Y, playing or
// paused". Pure. Ported from desktop/src/core/waterfall-protocol.ts. Messages
// are the JSON Maps that go over the socket (key `k` names the kind: state,
// hello, wrong-server, queue, control, enqueue, enqueue-rejected).
import 'dart:math';

/// Host re-announces its position this often.
const wfHeartbeatMs = 4000;

/// A guest re-seeks once it is at least this far out.
const wfDriftMs = 1500;

/// A `state` message. [index] (the host's queueIndex, riding the heartbeat) is left out when null so older clients still parse it.
Map<String, Object?> buildStateMessage({
  required String? serverId,
  required String trackId,
  required num positionMs,
  required bool paused,
  int? index,
  int? now,
}) =>
    {
      'k': 'state',
      'serverId': serverId,
      'trackId': trackId,
      'positionMs': positionMs,
      'paused': paused,
      'index': ?index,
      'sentAt': now ?? DateTime.now().millisecondsSinceEpoch,
    };

/// A `queue` message, host to everyone, sent only when the queue changes. [addedBy] is padded or trimmed to match [trackIds].
Map<String, Object?> buildQueueMessage({
  required String? serverId,
  required int rev,
  required List<String> trackIds,
  List<String?>? addedBy,
  required int index,
  required bool guestAddsAllowed,
  required bool guestControlAllowed,
}) {
  final ids = [...trackIds];
  return {
    'k': 'queue',
    'serverId': serverId,
    'rev': rev,
    'trackIds': ids,
    'addedBy': _alignAddedBy(addedBy, ids.length),
    'index': index,
    'guestAddsAllowed': guestAddsAllowed,
    'guestControlAllowed': guestControlAllowed,
  };
}

/// What a guest may ask the host to do to the transport.
const controlActions = ['playpause', 'next', 'prev', 'seek'];

/// A guest to host `control` message. Only `seek` carries a position, rounded and never negative; a missing or non-finite one is omitted.
Map<String, Object?> buildControlMessage(String action, [num? positionMs]) => {
      'k': 'control',
      'action': action,
      if (action == 'seek' && positionMs != null && positionMs.isFinite) 'positionMs': max(0, positionMs.round()),
    };

/// Whether [value] is a known control action. Control messages come from another client, so this is a trust boundary.
bool isControlAction(Object? value) => value is String && controlActions.contains(value);

/// A guest to host `enqueue` message: append-only, ids copied.
Map<String, Object?> buildEnqueueMessage({required String? serverId, required List<String> trackIds}) => {'k': 'enqueue', 'serverId': serverId, 'trackIds': [...trackIds]};

/// Host to the requesting guest, sent instead of dropping a request silently.
Map<String, Object?> buildEnqueueRejected(String reason) => {'k': 'enqueue-rejected', 'reason': reason};

List<String?> _alignAddedBy(List<String?>? addedBy, int length) {
  final out = (addedBy ?? const <String?>[]).take(length).toList();
  while (out.length < length) {
    out.add(null);
  }
  return out;
}

/// Whether an arriving queue message is older than (or the same as) what was already applied.
bool isStaleQueue(int incomingRev, int lastAppliedRev) => incomingRev <= lastAppliedRev;

/// Which of the host's track ids this member has no metadata for yet, once each, in order.
List<String> missingTrackIds(List<String> trackIds, Iterable<String> knownIds) {
  final known = knownIds.toSet();
  final out = <String>[];
  for (final id in trackIds) {
    if (known.contains(id) || out.contains(id)) continue;
    out.add(id);
  }
  return out;
}

num _numOr0(Object? v) => v is num && v != 0 && !v.isNaN ? v : 0;

/// Where the host should be now, aging a playing position by time in transit. [offsetMs] (from [clockOffsetMs]) takes clock skew back out. Time never runs backwards.
num expectedPositionMs(Map<String, Object?> state, {int? now, int offsetMs = 0}) {
  final n = now ?? DateTime.now().millisecondsSinceEpoch;
  final sentAt = _numOr0(state['sentAt']);
  final latency = max(0, n - (sentAt == 0 ? n : sentAt) - offsetMs);
  return _numOr0(state['positionMs']) + (state['paused'] == true ? 0 : latency);
}

/// The most a guest will lead a seek by, however slow the last one was.
const wfMaxSeekLeadMs = 5000;

/// Where a guest should seek so it comes out level with the host: leads a playing host by the last measured seek time (capped). A paused host is not moving.
num seekTargetMs(num expectedMs, num lastSeekMs, bool paused) {
  if (paused) return max(0, expectedMs);
  return max(0, expectedMs + min(max(0, lastSeekMs), wfMaxSeekLeadMs));
}

/// How many recent state messages [clockOffsetMs] looks at: two minutes of heartbeats.
const wfSkewWindow = 30;

/// This member's clock minus the host's, from `receivedAt - sentAt` of recent state messages: the smallest sample is the difference plus the fastest trip. Zero with no samples.
// ponytail: min over a window, no handshake, so it works against hosts that predate it.
num clockOffsetMs(Iterable<num> samples) {
  num best = double.infinity;
  for (final s in samples) {
    if (s < best) best = s;
  }
  return best.isInfinite ? 0 : best;
}

/// Whether a guest is far enough out ([driftMs]) to be worth re-seeking, ahead or behind.
bool shouldReseek(num currentMs, num expectedMs, [int driftMs = wfDriftMs]) => (currentMs - expectedMs).abs() > driftMs;

/// Whether a peer is on a different Jellyfin server. Unknown ids pass, so an older client is not locked out.
bool isForeignServer(String? peerServerId, String? ownServerId) {
  if (peerServerId == null || peerServerId.isEmpty || ownServerId == null || ownServerId.isEmpty) return false;
  return peerServerId != ownServerId;
}

/// Relay base (http) to room socket URL (ws), with the display name attached.
String roomSocketUrl(String relayBase, String code, String name) =>
    '${relayBase.replaceFirst(RegExp(r'/+$'), '').replaceFirst(RegExp(r'^http'), 'ws')}/room/$code?name=${Uri.encodeComponent(name)}';
