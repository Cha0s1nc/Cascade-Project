// The app bundles a copy of shared/tuning-defaults.json (an asset must live
// in the package). This fails when the copy is stale: copy it again.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('assets/tuning-defaults.json matches shared/tuning-defaults.json', () {
    expect(File('assets/tuning-defaults.json').readAsStringSync(), File('../shared/tuning-defaults.json').readAsStringSync());
  });
}
