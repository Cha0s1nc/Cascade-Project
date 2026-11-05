// Ported from desktop/test/ownership.test.ts.
import 'package:cascade/core/ownership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nobody in a room: the local user owns playback', () {
    const s = OwnershipState();
    expect(playbackOwner(s), 'local');
    expect(blocksLocalPlayback(s), isFalse);
    expect(acceptsRemoteCommand(s), isTrue);
  });

  test('waterfall guest: local controls are inert', () {
    const s = OwnershipState(waterfallActive: true);
    expect(playbackOwner(s), 'waterfall');
    expect(blocksLocalPlayback(s), isTrue);
  });

  test('waterfall host: own controls stay live, they drive the room', () {
    expect(blocksLocalPlayback(const OwnershipState(waterfallActive: true, waterfallIsHost: true)), isFalse);
  });

  test('guest applying host state is not blocked', () {
    expect(blocksLocalPlayback(const OwnershipState(waterfallActive: true, waterfallApplying: true)), isFalse);
  });

  test('cast is refused in a waterfall room, host or guest', () {
    expect(acceptsRemoteCommand(const OwnershipState(waterfallActive: true, waterfallIsHost: true)), isFalse);
    expect(acceptsRemoteCommand(const OwnershipState(waterfallActive: true)), isFalse);
  });

  test('waterfall outranks cast', () {
    expect(playbackOwner(const OwnershipState(waterfallActive: true)), 'waterfall');
  });

  test('remote volume: allowed outside any waterfall room, refused in one, host or guest alike', () {
    expect(acceptsRemoteVolumeCommand(const OwnershipState()), isTrue);
    expect(acceptsRemoteVolumeCommand(const OwnershipState(waterfallActive: true, waterfallIsHost: true)), isFalse);
    expect(acceptsRemoteVolumeCommand(const OwnershipState(waterfallActive: true)), isFalse);
  });

  test('remote volume: applying host state does not reopen it', () {
    expect(acceptsRemoteVolumeCommand(const OwnershipState(waterfallActive: true, waterfallApplying: true)), isFalse);
  });

  test('queue additions: solo and host mutate directly, a host is never restricted by its own toggle', () {
    expect(queueAdditionMode(const OwnershipState()), 'local');
    expect(queueAdditionMode(const OwnershipState(waterfallActive: true, waterfallIsHost: true)), 'local');
    expect(queueAdditionMode(const OwnershipState(waterfallActive: true, waterfallIsHost: true, guestAddsAllowed: false)), 'local');
  });

  test('queue additions: a guest proposes, is blocked when the host turns it off, and unknown means allowed', () {
    expect(queueAdditionMode(const OwnershipState(waterfallActive: true, guestAddsAllowed: true)), 'propose');
    expect(queueAdditionMode(const OwnershipState(waterfallActive: true, guestAddsAllowed: false)), 'blocked');
    expect(queueAdditionMode(const OwnershipState(waterfallActive: true)), 'propose');
  });

  test('queue additions stay independent of playback blocking', () {
    const s = OwnershipState(waterfallActive: true, guestAddsAllowed: true);
    expect(blocksLocalPlayback(s), isTrue);
    expect(queueAdditionMode(s), 'propose');
  });
}
