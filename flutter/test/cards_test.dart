// Card grids at many widths, with and without a subtitle and at the genre
// cards' 16:9: any overflow fails the test (Flutter reports it as an error).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/ui/pages/common.dart';

void main() {
  for (final (label, aspect, textHeight, subtitle) in [
    ('genre', 16 / 9, 36.0, ''),
    ('album', 1.0, 52.0, 'Artist · 2020'),
    ('poster', 2 / 3, 52.0, '2024'),
  ]) {
    testWidgets('$label cards fit at every width', (tester) async {
      for (final width in [360.0, 412.0, 700.0, 1000.0, 1440.0, 1920.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  CardGrid(
                    count: 12,
                    aspect: aspect,
                    textHeight: textHeight,
                    builder: (_, i) => MediaCard(title: 'A long name that runs on and on', subtitle: subtitle, art: inRainbows, aspect: aspect, onTap: () {}),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
      }
      addTearDown(tester.view.reset);
    });
  }
}
