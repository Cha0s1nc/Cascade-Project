// A platform's view of tuning-defaults.json: every value it ships with. Ported
// from desktop/src/core/tuning-defaults.ts. The desktop inlines the file at
// build time; here the caller loads shared/tuning-defaults.json (an asset) and
// hands the text in, so there is no second copy to go stale.
import 'dart:convert';

import 'tuning.dart';

/// One platform's defaults, from the file's text.
class TuningDefaults {
  final TuningFile file;
  final String platform;
  final Map<String, Map<String, double>> _numbers = {};

  TuningDefaults(String json, {this.platform = 'desktop'}) : file = jsonDecode(json) as Map<String, dynamic>;

  /// One section's values for this platform.
  Map<String, Object?> section(String section) => resolveSection(file, section, platform);

  /// A number this platform must have. Missing means a broken file, so it throws rather than make up a default.
  double shippedNumber(String section, String key) {
    final v = (_numbers[section] ??= resolveNumbers(file, section, platform))[key];
    if (v == null) throw StateError('tuning-defaults.json: no $platform number for $section.$key');
    return v;
  }

  /// The latest defaults revision.
  int get revision => latestRevision(file);

  /// The style keys revision [r] moved on this platform.
  List<String> revisionKeysOf(int r) => revisionKeys(file, platform, r);
}
