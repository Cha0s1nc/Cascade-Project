/**
 * Wiring proof: @cascade/core parsing a real value, plus a round trip through
 * the platform store. No navigation, no styling - Phase 1 just proves the
 * monorepo/Metro/platform plumbing works end to end.
 *
 * @format
 */

import { useEffect, useState } from 'react';
import { SafeAreaView, ScrollView, StyleSheet, Text } from 'react-native';

import { parseLRC } from '@cascade/core';

import { platform } from './src/platform';

const SAMPLE_LRC = '[00:01.00]hello from cascade/core\n[00:04.50]running inside react-native-tvos';

function App() {
  const [lines, setLines] = useState<string[]>([]);
  const [storeRoundTrip, setStoreRoundTrip] = useState<string>('pending...');
  const [version, setVersion] = useState<string>('pending...');

  useEffect(() => {
    const parsed = parseLRC(SAMPLE_LRC);
    setLines(parsed.map((l) => `${l.Start}: ${l.Text}`));

    (async () => {
      await platform.store.set('wiringProof', { ok: true, ts: Date.now() });
      const readBack = await platform.store.get('wiringProof');
      setStoreRoundTrip(JSON.stringify(readBack));
      setVersion(await platform.getVersion());
    })();
  }, []);

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentInsetAdjustmentBehavior="automatic">
        <Text style={styles.heading}>@cascade/core wiring proof</Text>

        <Text style={styles.label}>platform.platform:</Text>
        <Text style={styles.value}>{platform.platform}</Text>

        <Text style={styles.label}>platform.getVersion():</Text>
        <Text style={styles.value}>{version}</Text>

        <Text style={styles.label}>platform.store round trip (wiringProof):</Text>
        <Text style={styles.value}>{storeRoundTrip}</Text>

        <Text style={styles.label}>parseLRC(SAMPLE_LRC) from @cascade/core:</Text>
        {lines.map((line) => (
          <Text key={line} style={styles.value}>
            {line}
          </Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  heading: {
    fontSize: 20,
    fontWeight: '600',
    margin: 16,
  },
  label: {
    marginHorizontal: 16,
    marginTop: 12,
    fontWeight: '600',
  },
  value: {
    marginHorizontal: 16,
  },
});

export default App;
