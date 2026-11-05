import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/platform/discord.dart';

void main() {
  test('a frame is op and length, little-endian, then the JSON', () {
    final f = discordFrame(1, {'cmd': 'SET_ACTIVITY'});
    final b = ByteData.sublistView(f);
    expect(b.getInt32(0, Endian.little), 1);
    expect(b.getInt32(4, Endian.little), f.length - 8);
    expect(jsonDecode(utf8.decode(f.sublist(8))), {'cmd': 'SET_ACTIVITY'});
  });

  test('the activity carries both timestamps so Discord draws the bar', () {
    final a = presenceActivity(reckoner, 1000);
    expect(a['details'], 'Reckoner');
    expect(a['state'], 'Radiohead');
    expect(a['timestamps'], {'start': 1000, 'end': 1000 + 290 * 1000});
    expect(a['assets'], {'large_text': 'In Rainbows'});
  });
}
