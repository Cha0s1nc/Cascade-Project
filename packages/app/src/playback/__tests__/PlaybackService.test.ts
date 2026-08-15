/**
 * PlaybackService owns the one bit of non-trivial state in this phase: which
 * track is loaded, whether the stream is direct or transcoded, and what gets
 * reported to Jellyfin - none of which a device is available to exercise for
 * real. This mocks @cascade/core and the shared client so the state machine
 * itself (not react-native-video, not the network) is what's under test.
 *
 * @format
 */
import type { JfItem, ResolvedStream } from '@cascade/core';

const mockClient = { artUrl: jest.fn(() => 'https://jf.test/art.jpg') };
const mockConfig = { url: 'https://jf.test', token: 'T', userId: 'U', deviceId: 'D' };

jest.mock('../../api/client', () => ({
  getJellyfinClient: () => mockClient,
  getServerConfig: () => mockConfig,
}));

const mockResolveStream = jest.fn();
const mockStopActiveEncoding = jest.fn();
const mockReportStart = jest.fn();
const mockReportProgress = jest.fn();
const mockReportStopped = jest.fn();

jest.mock('@cascade/core', () => {
  const actual = jest.requireActual('@cascade/core');
  return {
    ...actual,
    resolveStream: (...args: unknown[]) => mockResolveStream(...args),
    stopActiveEncoding: (...args: unknown[]) => mockStopActiveEncoding(...args),
    reportStart: (...args: unknown[]) => mockReportStart(...args),
    reportProgress: (...args: unknown[]) => mockReportProgress(...args),
    reportStopped: (...args: unknown[]) => mockReportStopped(...args),
  };
});

// eslint-disable-next-line import/first
import { playbackService } from '../PlaybackService';

const track = (id: string, name: string): JfItem => ({ Id: id, Name: name, Type: 'Audio' });

const direct = (id: string): ResolvedStream =>
  ({ url: `https://jf.test/Audio/${id}/stream.flac`, playSessionId: `PS-${id}`, mediaSourceId: `MS-${id}`, direct: true, startTicks: 0 });

const transcode = (id: string): ResolvedStream =>
  ({ url: `https://jf.test/Audio/${id}/main.m3u8`, playSessionId: `PS-${id}`, mediaSourceId: `MS-${id}`, direct: false, startTicks: 0 });

beforeEach(() => {
  jest.clearAllMocks();
  playbackService.stop();
  jest.clearAllMocks(); // stop() from a clean state reports nothing, but be sure
});

// Every test that calls play() starts a real setInterval (startReporting) -
// left running past the test, it's a leaked timer that keeps the Jest worker
// alive. stop() is what tears it down, same as it would for a real skip-away.
afterEach(() => {
  playbackService.stop();
});

test('play() resolves the tapped track and reports start', async () => {
  mockResolveStream.mockResolvedValue(direct('A'));
  const items = [track('A', 'Song A'), track('B', 'Song B')];

  await playbackService.play(items, 0);

  const snap = playbackService.getSnapshot();
  expect(snap.item?.Id).toBe('A');
  expect(snap.index).toBe(0);
  expect(snap.isPaused).toBe(false);
  expect(snap.source?.uri).toContain('stream.flac');
  expect(mockReportStart).toHaveBeenCalledTimes(1);
});

test('play() starts from the tapped index, not always the first track', async () => {
  mockResolveStream.mockResolvedValue(direct('B'));
  const items = [track('A', 'Song A'), track('B', 'Song B'), track('C', 'Song C')];

  await playbackService.play(items, 1);

  expect(playbackService.getSnapshot().item?.Id).toBe('B');
});

test('pause/resume flip isPaused without touching the loaded track', async () => {
  mockResolveStream.mockResolvedValue(direct('A'));
  await playbackService.play([track('A', 'Song A')], 0);

  playbackService.pause();
  expect(playbackService.getSnapshot().isPaused).toBe(true);
  expect(playbackService.getSnapshot().item?.Id).toBe('A');

  playbackService.resume();
  expect(playbackService.getSnapshot().isPaused).toBe(false);
});

test('next() advances and reports the outgoing track stopped', async () => {
  mockResolveStream.mockResolvedValueOnce(direct('A')).mockResolvedValueOnce(direct('B'));
  await playbackService.play([track('A', 'Song A'), track('B', 'Song B')], 0);

  playbackService.next();
  await Promise.resolve(); // let the pending resolveStream microtask settle

  expect(playbackService.getSnapshot().item?.Id).toBe('B');
  expect(mockReportStopped).toHaveBeenCalledTimes(1);
});

test('next() at the end of the queue stops rather than looping', async () => {
  mockResolveStream.mockResolvedValue(direct('A'));
  await playbackService.play([track('A', 'Song A')], 0);

  playbackService.next();

  expect(playbackService.getSnapshot().item).toBeNull();
  expect(mockReportStopped).toHaveBeenCalledTimes(1);
});

test('previous() before the first track is a no-op', async () => {
  mockResolveStream.mockResolvedValue(direct('A'));
  await playbackService.play([track('A', 'Song A')], 0);

  playbackService.previous();

  expect(playbackService.getSnapshot().item?.Id).toBe('A');
});

test('switching tracks abandons an active transcode', async () => {
  mockResolveStream.mockResolvedValueOnce(transcode('A')).mockResolvedValueOnce(direct('B'));
  await playbackService.play([track('A', 'Song A'), track('B', 'Song B')], 0);

  playbackService.next();
  await Promise.resolve();

  expect(mockStopActiveEncoding).toHaveBeenCalledWith(mockClient, mockConfig, 'PS-A');
});

test('stop() reports stopped, clears the snapshot, and abandons a transcode', async () => {
  mockResolveStream.mockResolvedValue(transcode('A'));
  await playbackService.play([track('A', 'Song A')], 0);

  playbackService.stop();

  expect(playbackService.getSnapshot().item).toBeNull();
  expect(playbackService.getSnapshot().source).toBeNull();
  expect(mockReportStopped).toHaveBeenCalledTimes(1);
  expect(mockStopActiveEncoding).toHaveBeenCalledWith(mockClient, mockConfig, 'PS-A');
});

test('a failed resolve surfaces an error instead of leaving a stale snapshot', async () => {
  mockResolveStream.mockRejectedValue(new Error('server unreachable'));

  await playbackService.play([track('A', 'Song A')], 0);

  const snap = playbackService.getSnapshot();
  expect(snap.isLoading).toBe(false);
  expect(snap.error).toBe('server unreachable');
  expect(mockReportStart).not.toHaveBeenCalled();
});

test('subscribers are notified on every state change', async () => {
  mockResolveStream.mockResolvedValue(direct('A'));
  const listener = jest.fn();
  const unsubscribe = playbackService.subscribe(listener);

  await playbackService.play([track('A', 'Song A')], 0);
  expect(listener).toHaveBeenCalled();

  listener.mockClear();
  playbackService.pause();
  expect(listener).toHaveBeenCalledTimes(1);

  unsubscribe();
});
