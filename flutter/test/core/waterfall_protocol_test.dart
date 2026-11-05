// Ported from desktop/test/waterfall-protocol.test.ts.
import 'package:cascade/core/waterfall_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> state(num pos, bool paused) => buildStateMessage(serverId: 'S1', trackId: 'T1', positionMs: pos, paused: paused, now: 1000000);

void main() {
  test('buildStateMessage stamps the send time', () {
    expect(buildStateMessage(serverId: 'S1', trackId: 'T1', positionMs: 5000, paused: false, now: 1000000), {
      'k': 'state',
      'serverId': 'S1',
      'trackId': 'T1',
      'positionMs': 5000,
      'paused': false,
      'sentAt': 1000000,
    });
    expect(buildStateMessage(serverId: 'S1', trackId: 'T1', positionMs: 1, paused: true, index: 3, now: 5)['index'], 3);
  });

  test('expectedPositionMs ages a playing position by time in transit', () {
    expect(expectedPositionMs(state(10000, false), now: 1000300), 10300);
  });

  test('clockOffsetMs cancels a skewed clock out of expectedPositionMs', () {
    const skew = 3000;
    final samples = [120, 40, 200, 75].map((t) => skew + t).toList();
    final offset = clockOffsetMs(samples);
    expect(offset, skew + 40);
    final msg = state(10000, false);
    const now = 1000000 + skew + 100;
    expect(expectedPositionMs(msg, now: now), 13100);
    expect(expectedPositionMs(msg, now: now, offsetMs: offset.toInt()), 10060);
  });

  test('seekTargetMs leads a playing host by the last seek time', () {
    expect(seekTargetMs(60000, 1800, false), 61800);
    expect(shouldReseek(61800, 60000 + 1800), isFalse);
    expect(seekTargetMs(60000, 1800, true), 60000);
    expect(seekTargetMs(60000, 60000, false), 60000 + wfMaxSeekLeadMs);
    expect(seekTargetMs(60000, -50, false), 60000);
  });

  test('clockOffsetMs is zero with nothing measured yet', () {
    expect(clockOffsetMs([]), 0);
  });

  test('expectedPositionMs does not age a paused position, and ignores a clock running backwards', () {
    expect(expectedPositionMs(state(10000, true), now: 1005000), 10000);
    expect(expectedPositionMs(state(10000, false), now: 999000), 10000);
  });

  test('shouldReseek only fires past the drift threshold', () {
    expect(shouldReseek(10000, 10000 + wfDriftMs - 1), isFalse);
    expect(shouldReseek(10000, 10000 + wfDriftMs + 1), isTrue);
    expect(shouldReseek(10000, 10000 - wfDriftMs - 1), isTrue);
  });

  test('isForeignServer refuses a different server but tolerates unknowns', () {
    expect(isForeignServer('A', 'B'), isTrue);
    expect(isForeignServer('A', 'A'), isFalse);
    expect(isForeignServer(null, 'A'), isFalse);
    expect(isForeignServer('A', null), isFalse);
    expect(isForeignServer(null, null), isFalse);
  });

  test('roomSocketUrl upgrades the scheme, encodes the name, tolerates a trailing slash', () {
    expect(roomSocketUrl('https://relay.test', 'ABC123', 'Jon'), 'wss://relay.test/room/ABC123?name=Jon');
    expect(roomSocketUrl('http://relay.test', 'ABC123', 'a b&c'), 'ws://relay.test/room/ABC123?name=a%20b%26c');
    expect(roomSocketUrl('https://relay.test/', 'ABC123', 'Jon'), 'wss://relay.test/room/ABC123?name=Jon');
  });

  test('buildQueueMessage pads and trims attribution, copies its inputs, carries both permissions', () {
    var msg = buildQueueMessage(
      serverId: 'S1',
      rev: 3,
      trackIds: ['a', 'b', 'c'],
      addedBy: ['Jon'],
      index: 0,
      guestAddsAllowed: true,
      guestControlAllowed: false,
    );
    expect(msg['addedBy'], ['Jon', null, null]);
    expect(msg['guestAddsAllowed'], true);
    expect(msg['guestControlAllowed'], false);
    msg = buildQueueMessage(
      serverId: 'S1',
      rev: 1,
      trackIds: ['a'],
      addedBy: ['Jon', 'Sam', 'Alex'],
      index: 0,
      guestAddsAllowed: true,
      guestControlAllowed: false,
    );
    expect(msg['addedBy'], ['Jon']);
    final ids = ['a', 'b'];
    msg = buildQueueMessage(serverId: null, rev: 1, trackIds: ids, index: 0, guestAddsAllowed: false, guestControlAllowed: true);
    ids.add('c');
    expect(msg['trackIds'], ['a', 'b']);
  });

  test('isStaleQueue drops older and duplicate revisions', () {
    expect(isStaleQueue(5, 4), isFalse);
    expect(isStaleQueue(4, 4), isTrue);
    expect(isStaleQueue(3, 4), isTrue);
  });

  test('missingTrackIds returns only unknown ids, once each', () {
    expect(missingTrackIds(['a', 'b', 'c', 'b', 'd'], ['a', 'c']), ['b', 'd']);
    expect(missingTrackIds(['a', 'b'], []), ['a', 'b']);
  });

  test('buildEnqueueMessage is append-only and copies its ids; rejected carries a reason', () {
    final ids = ['x'];
    final msg = buildEnqueueMessage(serverId: 'S1', trackIds: ids);
    ids.add('y');
    expect(msg, {
      'k': 'enqueue',
      'serverId': 'S1',
      'trackIds': ['x'],
    });
    expect(buildEnqueueRejected('Host cannot access that track'), {'k': 'enqueue-rejected', 'reason': 'Host cannot access that track'});
  });

  test('buildControlMessage only carries a position for seek, normalised', () {
    expect(buildControlMessage('playpause'), {'k': 'control', 'action': 'playpause'});
    expect(buildControlMessage('next'), {'k': 'control', 'action': 'next'});
    expect(buildControlMessage('prev', 5000), {'k': 'control', 'action': 'prev'});
    expect(buildControlMessage('seek', 5000), {'k': 'control', 'action': 'seek', 'positionMs': 5000});
    expect(buildControlMessage('seek', -50)['positionMs'], 0);
    expect(buildControlMessage('seek', 1234.7)['positionMs'], 1235);
    expect(buildControlMessage('seek', double.nan).containsKey('positionMs'), isFalse);
    expect(buildControlMessage('seek').containsKey('positionMs'), isFalse);
  });

  test('isControlAction rejects anything unrecognised', () {
    for (final ok in ['playpause', 'next', 'prev', 'seek']) {
      expect(isControlAction(ok), isTrue);
    }
    for (final bad in [
      'stop',
      'eval',
      '',
      'PLAYPAUSE',
      null,
      7,
      {},
      ['next'],
    ]) {
      expect(isControlAction(bad), isFalse, reason: '$bad must be refused');
    }
  });
}
