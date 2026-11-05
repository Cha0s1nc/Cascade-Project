// Ported from desktop/test/session-control.test.ts.
import 'package:cascade/core/session_control.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> session([Map<String, dynamic> over = const {}]) => {'Id': 's1', 'DeviceId': 'other-device', 'SupportsRemoteControl': true, ...over};
List ids(List<Map<String, dynamic>> l) => l.map((s) => s['Id']).toList();

void main() {
  test('filterControllableSessions drops our own device', () {
    expect(ids(filterControllableSessions([session({'Id': 'a', 'DeviceId': 'me'}), session({'Id': 'b', 'DeviceId': 'other'})], 'me')), ['b']);
  });

  test('filterControllableSessions drops sessions that cannot be remote controlled', () {
    expect(ids(filterControllableSessions([session({'Id': 'a', 'SupportsRemoteControl': false}), session({'Id': 'b'})], 'me')), ['b']);
  });

  test('filterControllableSessions treats a null DeviceId as not-us', () {
    expect(ids(filterControllableSessions([session({'Id': 'a', 'DeviceId': null})], 'me')), ['a']);
  });

  test('secondsToTicks converts and floors garbage to zero', () {
    expect(secondsToTicks(1), 10000000);
    expect(secondsToTicks(0.5), 5000000);
    expect(secondsToTicks(double.nan), 0);
    expect(secondsToTicks(-5), 0);
    expect(secondsToTicks(double.infinity), 0);
  });

  test('clampVolumePercent keeps a corrupted value off the wire as NaN', () {
    expect(clampVolumePercent(50), 50);
    expect(clampVolumePercent(-10), 0);
    expect(clampVolumePercent(150), 100);
    expect(clampVolumePercent(double.nan), 0);
    expect(clampVolumePercent(null), 0);
  });

  test('buildPlayOnDeviceParams refuses an empty item list', () {
    expect(buildPlayOnDeviceParams([]), isNull);
    expect(buildPlayOnDeviceParams(['', '']), isNull);
  });

  test('buildPlayOnDeviceParams builds the play-now default, or carries a start index and explicit command', () {
    final p = buildPlayOnDeviceParams(['a', 'b'])!;
    expect(p.playCommand, 'PlayNow');
    expect(p.itemIds, ['a', 'b']);
    expect(p.startIndex, 0);
    final q = buildPlayOnDeviceParams(['a', 'b', 'c'], playCommand: 'PlayNext', startIndex: 2)!;
    expect(q.playCommand, 'PlayNext');
    expect(q.itemIds, ['a', 'b', 'c']);
    expect(q.startIndex, 2);
  });

  test('buildSetVolumeCommand carries the volume as a string, clamped', () {
    expect(buildSetVolumeCommand(40), {'Name': 'SetVolume', 'Arguments': {'Volume': '40'}});
    expect(buildSetVolumeCommand(double.nan), {'Name': 'SetVolume', 'Arguments': {'Volume': '0'}});
  });

  test('interpolatedPositionTicks holds still while paused, projects forward while playing, is 0 with no state', () {
    expect(interpolatedPositionTicks({'PositionTicks': 1000, 'IsPaused': true}, 0, 5000), 1000);
    expect(interpolatedPositionTicks({'PositionTicks': 0, 'IsPaused': false}, 0, 2000), 20000000);
    expect(interpolatedPositionTicks(null, 0, 5000), 0);
    expect(interpolatedPositionTicks({}, 0, 5000), 0);
  });
}
