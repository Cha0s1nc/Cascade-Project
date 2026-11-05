// Ported from desktop/test/offline-mode.test.ts.
import 'package:cascade/core/offline_mode.dart';
import 'package:flutter_test/flutter_test.dart';

const on = OfflineSwitch(true), off = OfflineSwitch(false), lost = OfflineUnreachable(), back = OfflineReachable();
const online = OfflineState.online, manual = OfflineState.manual, unreachable = OfflineState.unreachable, local = OfflineState.local;

void main() {
  test('the manual switch outranks what the network says', () {
    var s = online;
    s = nextOfflineState(s, on);
    expect(s, manual);
    expect(nextOfflineState(s, back), manual);
    expect(nextOfflineState(s, lost), manual);
    expect(nextOfflineState(s, off), online);
  });

  test('a drop turns it on by itself and an answer turns it off', () {
    var s = online;
    s = nextOfflineState(s, lost);
    expect(s, unreachable);
    expect(nextOfflineState(s, lost), unreachable);
    expect(nextOfflineState(s, back), online);
    expect(nextOfflineState(s, on), manual);
    expect(nextOfflineState(s, off), unreachable);
  });

  test('only online is online', () {
    expect(isOffline(online), isFalse);
    expect(isOffline(manual), isTrue);
    expect(isOffline(unreachable), isTrue);
  });

  test('probes back off from 30 s to five minutes', () {
    expect([0, 1, 2, 3, 4, 5, 50].map(probeDelayMs), [30000, 60000, 120000, 240000, 300000, 300000, 300000]);
    expect(probeDelayMs(-1), 30000);
  });

  test('an expired session is never Offline Mode', () {
    expect(failureKind(null), 'unreachable');
    expect(failureKind(0), 'unreachable');
    for (final s in [502, 503, 504]) {
      expect(failureKind(s), 'unreachable', reason: '$s');
    }
    expect(failureKind(401), 'auth');
    expect(failureKind(403), 'auth');
    for (final s in [400, 404, 500]) {
      expect(failureKind(s), 'error', reason: '$s');
    }
  });

  test('the server is blocked only for the switch; updates wait until online', () {
    expect(blocksServer(manual), isTrue);
    expect(blocksServer(unreachable), isFalse);
    expect(blocksServer(online), isFalse);
    expect(checksUpdates(online), isTrue);
    expect(checksUpdates(manual), isFalse);
    expect(updateCheckDue(unreachable, online), isTrue);
    expect(updateCheckDue(manual, online), isTrue);
    expect(updateCheckDue(online, online), isFalse);
    expect(updateCheckDue(online, manual), isFalse);
  });

  test('Local mode has no server to lose, but the web is there', () {
    for (final e in [on, off, lost, back]) {
      expect(nextOfflineState(local, e), local);
    }
    expect(isOffline(local), isTrue);
    expect(blocksServer(local), isFalse);
    expect(blocksWeb(local), isFalse);
    expect(blocksWeb(manual), isTrue);
    expect(blocksWeb(unreachable), isTrue);
    expect(blocksWeb(online), isFalse);
    expect(checksUpdates(local), isTrue);
    expect(updateCheckDue(online, local), isFalse);
    expect(updateCheckDue(manual, local), isTrue);
    expect(updateCheckDue(local, online), isFalse);
  });

  test('only the four states are accepted from outside', () {
    for (final s in ['online', 'manual', 'unreachable', 'local']) {
      expect(offlineStateFrom(s), isNotNull, reason: s);
    }
    for (final s in ['Local', '', null, 1, {}]) {
      expect(offlineStateFrom(s), isNull, reason: '$s');
    }
  });
}
