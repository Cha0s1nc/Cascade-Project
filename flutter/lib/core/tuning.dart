// Reading side of shared/tuning-defaults.json: every app's shipped defaults,
// each either shared or split per platform. Pure. Ported from
// desktop/src/core/tuning.ts. The editing side (set, bake, combine, revision
// recording, formatTuning, swiftCopy) belongs to the repo's tuning script and
// is not ported.

/// The platforms a tuning file knows. Entries resolve for one of these.
const tuningPlatforms = ['desktop', 'mac', 'ios', 'tvos'];
const tuningTargets = ['all', 'apple', ...tuningPlatforms];

/// Sections of the file, in the order the file has them.
const tuningSections = ['style', 'albumColors', 'motion'];

/// Most specific first: what a platform reads, in the order it looks.
const tuningChain = {
  'desktop': ['desktop', 'all'],
  'mac': ['mac', 'apple', 'all'],
  'ios': ['ios', 'apple', 'all'],
  'tvos': ['tvos', 'apple', 'all'],
};

/// The platforms a target reaches.
List<String> platformsOf(String target) => [
  for (final p in tuningPlatforms)
    if (tuningChain[p]!.contains(target)) p,
];

/// A split entry is a Map (not a List) whose keys are all targets or `note`. Anything else is one shared value.
bool isSplit(Object? entry) {
  if (entry is! Map || entry.isEmpty) return false;
  return entry.keys.every((k) => k == 'note' || tuningTargets.contains(k));
}

/// What one platform reads from an entry, or null when it has none.
Object? resolveEntry(Object? entry, String platform) {
  if (!isSplit(entry)) return entry;
  final m = entry as Map;
  for (final t in tuningChain[platform]!) {
    if (m.containsKey(t)) return m[t];
  }
  return null;
}

/// The parsed file: `style`, `albumColors`, `motion` and `revisions` maps.
typedef TuningFile = Map<String, dynamic>;

/// Every key of a section this platform has, resolved.
Map<String, Object?> resolveSection(TuningFile file, String section, String platform) {
  final out = <String, Object?>{};
  final s = file[section];
  if (s is Map) {
    for (final e in s.entries) {
      final v = resolveEntry(e.value, platform);
      if (v != null) out['${e.key}'] = v;
    }
  }
  return out;
}

/// The numbers of a section only, for the knob tables.
Map<String, double> resolveNumbers(TuningFile file, String section, String platform) => {
  for (final e in resolveSection(file, section, platform).entries)
    if (e.value is num && (e.value as num).isFinite) e.key: (e.value as num).toDouble(),
};

/// The latest defaults revision (at least 1).
int latestRevision(TuningFile file) {
  final r = file['revisions'];
  var best = 1;
  if (r is Map) {
    for (final k in r.keys) {
      final n = int.tryParse('$k');
      if (n != null && n > best) best = n;
    }
  }
  return best;
}

/// The style keys whose default moved on this platform in revision [r].
List<String> revisionKeys(TuningFile file, String platform, int r) {
  final revs = file['revisions'];
  final rev = revs is Map ? revs['$r'] : null;
  if (rev is! Map) return [];
  final keys = <String>{};
  for (final t in tuningChain[platform]!) {
    final list = rev[t];
    if (list is List) keys.addAll(list.whereType<String>());
  }
  return keys.toList();
}
