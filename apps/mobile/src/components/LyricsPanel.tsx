/**
 * Synced lyrics, ported from the desktop overlay's lyrics pane.
 *
 * Everything that decides *what* is shown lives in @cascade/core - which source
 * wins, which line is current, the lookahead constant. This is the scrolling and
 * the tapping.
 *
 * @format
 */
import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { activeLineIndex, fetchLyricsWaterfall, isInstrumental } from '@cascade/core';
import type { JfItem, LyricLine, LyricsResult } from '@cascade/core';

import { getServerConfig } from '../api/client';
import { getKugouKrc } from '../lyrics/kugou';
import { playbackService, usePlaybackSnapshot } from '../playback/PlaybackService';
import { colors, radius, spacing, type as typeScale } from '../theme';

type State =
  | { status: 'loading' }
  | { status: 'none' }
  | { status: 'instrumental' }
  | { status: 'ok'; result: LyricsResult };

export default function LyricsPanel({ item }: { item: JfItem }) {
  const snapshot = usePlaybackSnapshot();
  const [state, setState] = useState<State>({ status: 'loading' });
  const [active, setActive] = useState(-1);

  const scroller = useRef<ScrollView>(null);
  const offsets = useRef<number[]>([]);
  const viewport = useRef(0);
  // The previous answer, so core can resume its scan instead of rescanning the
  // whole song on every tick.
  const cursor = useRef(0);

  useEffect(() => {
    let live = true;
    setState({ status: 'loading' });
    setActive(-1);
    cursor.current = 0;
    offsets.current = [];

    (async () => {
      const { url, token } = getServerConfig();
      const found = await fetchLyricsWaterfall({ serverUrl: url, token, getKugouKrc }, item);
      if (!live) return;
      if (!found) setState({ status: 'none' });
      else if (isInstrumental(found)) setState({ status: 'instrumental' });
      else setState({ status: 'ok', result: found });
    })();

    return () => {
      live = false;
    };
  }, [item.Id, item]);

  // Follow playback.
  const lines = state.status === 'ok' ? state.result.lines : null;
  useEffect(() => {
    if (!lines) return;
    const idx = activeLineIndex(lines, snapshot.positionSec, cursor.current);
    cursor.current = Math.max(0, idx);
    setActive(idx);
  }, [lines, snapshot.positionSec]);

  // Centre the active line. Not animated on tvOS: the list is driven entirely by
  // the clock there, and an animation still running when the next line lands
  // stacks up into a visible lurch.
  useEffect(() => {
    const y = offsets.current[active];
    if (y == null || !scroller.current) return;
    scroller.current.scrollTo({
      y: Math.max(0, y - viewport.current / 2),
      animated: !Platform.isTV,
    });
  }, [active]);

  if (state.status === 'loading') {
    return (
      <View style={styles.status}>
        <ActivityIndicator color={colors.accent} />
      </View>
    );
  }

  if (state.status !== 'ok') {
    return (
      <View style={styles.status}>
        <Text style={styles.statusText}>
          {state.status === 'instrumental' ? 'Instrumental' : 'No lyrics found'}
        </Text>
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <Text style={styles.source}>{state.result.source}</Text>
      <ScrollView
        ref={scroller}
        style={styles.scroll}
        contentContainerStyle={styles.content}
        onLayout={e => {
          viewport.current = e.nativeEvent.layout.height;
        }}
        showsVerticalScrollIndicator={false}>
        {state.result.lines.map((line, i) => (
          <LyricRow
            key={i}
            line={line}
            active={i === active}
            onLayout={y => {
              offsets.current[i] = y;
            }}
          />
        ))}
      </ScrollView>
    </View>
  );
}

function LyricRow({
  line,
  active,
  onLayout,
}: {
  line: LyricLine;
  active: boolean;
  onLayout: (y: number) => void;
}) {
  // A line with no timestamp came from an unsynced source. It still shows, but
  // seeking to it would be a guess, so it is not a button.
  const seekable = line.Start != null;

  const body = (
    <Text style={[styles.line, active && styles.lineActive, !seekable && styles.linePlain]}>
      {line.Text}
    </Text>
  );

  return (
    <View onLayout={e => onLayout(e.nativeEvent.layout.y)}>
      {seekable ? (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={`Seek to ${line.Text}`}
          onPress={() => void playbackService.seek((line.Start as number) / 10_000_000)}
          style={({ focused, pressed }) => [styles.row, (focused || pressed) && styles.rowFocused]}>
          {body}
        </Pressable>
      ) : (
        <View style={styles.row}>{body}</View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, minHeight: 0 },
  source: {
    fontSize: typeScale.hint,
    color: colors.text3,
    textTransform: 'uppercase',
    letterSpacing: 1,
    fontWeight: '600',
    marginBottom: spacing.sm,
  },
  // No `flex: 1` - see the comment on MediaGrid's `container`.
  scroll: { backgroundColor: 'transparent' },
  content: { paddingVertical: spacing.xxl },
  row: { paddingVertical: spacing.xs, paddingHorizontal: spacing.sm, borderRadius: radius.sm },
  rowFocused: { outlineWidth: 3, outlineColor: colors.text },
  line: {
    fontSize: typeScale.body,
    color: colors.text3,
    fontWeight: '600',
    lineHeight: typeScale.body * 1.45,
  },
  lineActive: { color: colors.text },
  linePlain: { color: colors.text2, fontWeight: '400' },
  status: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl },
  statusText: { fontSize: typeScale.body, color: colors.text3 },
});
