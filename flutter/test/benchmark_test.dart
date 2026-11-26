import 'package:flutter_test/flutter_test.dart';

import 'package:cascade/core/benchmark.dart';

void main() {
  test('benchmark flags', () {
    expect(benchmarkArgs(['--other']), isNull);
    expect(benchmarkArgs(['--benchmark']), (track: null, settle: 20, seconds: 30, out: null));
    expect(
      benchmarkArgs(['--benchmark', '--benchmark-track=abc', '--benchmark-settle=5', '--benchmark-seconds=0', '--benchmark-out=/tmp/r.json']),
      (track: 'abc', settle: 5, seconds: 30, out: '/tmp/r.json'),
    );
  });

  test('summary line', () {
    final r = {
      'memoryKind': 'private',
      'idle': {'cpuPercent': 0.6, 'memoryMB': 161},
      'playing': {'cpuPercent': null, 'memoryMB': 158},
    };
    expect(benchmarkSummary(r), 'Idle 0.6% CPU, 161 MB private. Playing ?% CPU, 158 MB private.');
  });

  test('reads its own CPU and memory here', () {
    expect(memoryKB(), greaterThan(0));
    final c = cpuSeconds();
    if (c != null) expect(c, greaterThan(0));
  });
}
