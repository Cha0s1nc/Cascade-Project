// Bulk playlist editing, the write gate, and picture sniffing. Pure. Ported
// from desktop/src/core/playlist-edit.ts (bytesToBase64 is dart:convert's base64Encode).
import 'dart:math';
import 'dart:typed_data';

import 'jellyfin.dart' show Item;

/// The id of one playlist row: PlaylistItemId when present (a track can repeat), else Id.
String entryIdOf(Item item) {
  final p = item['PlaylistItemId'];
  return p is String && p.isNotEmpty ? p : '${item['Id']}';
}

/// Every selected row dropped, the rest in order.
List<Item> removeSelected(List<Item> items, Set<String> selected) => items.where((i) => !selected.contains(entryIdOf(i))).toList();

/// Selected rows pulled to the front, relative order kept.
List<Item> moveSelectedToTop(List<Item> items, Set<String> selected) => [
      ...items.where((i) => selected.contains(entryIdOf(i))),
      ...items.where((i) => !selected.contains(entryIdOf(i))),
    ];

/// Selected rows pushed to the back, relative order kept.
List<Item> moveSelectedToBottom(List<Item> items, Set<String> selected) => [
      ...items.where((i) => !selected.contains(entryIdOf(i))),
      ...items.where((i) => selected.contains(entryIdOf(i))),
    ];

/// Spaces writes to one playlist [spacingMs] apart (Jellyfin loses a write that lands inside its own background save). Await the returned function before each write.
Future<void> Function(String playlistId) createPlaylistWriteGate({
  int spacingMs = 400,
  int Function()? now,
  Future<void> Function(int ms)? sleep,
}) {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  final nap = sleep ?? (int ms) => Future<void>.delayed(Duration(milliseconds: ms));
  final nextSlot = <String, int>{};
  return (playlistId) async {
    final t = clock();
    final slot = max(t, nextSlot[playlistId] ?? t);
    nextSlot[playlistId] = slot + spacingMs;
    if (slot > t) await nap(slot - t);
  };
}

/// Largest playlist picture accepted.
const playlistImageMaxBytes = 10 * 1024 * 1024;

/// Longest playlist description accepted.
const playlistOverviewMax = 2000;

/// What an image really is from its first bytes (JPEG, PNG, WebP), else null.
String? sniffImageType(Uint8List bytes) {
  bool at(int i, List<int> v) {
    for (var k = 0; k < v.length; k++) {
      if (bytes[i + k] != v[k]) return false;
    }
    return true;
  }

  if (bytes.length >= 3 && at(0, [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (bytes.length >= 8 && at(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png';
  if (bytes.length >= 12 && at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  return null;
}

/// How picture and description can change: 'plugin' (Cascade Server), 'admin' (Jellyfin routes), or null.
String? playlistDetailsRoute(Set<String> pluginCaps, bool pluginPresent, bool isAdmin) {
  if (pluginPresent && pluginCaps.contains('playlist-edit')) return 'plugin';
  return isAdmin ? 'admin' : null;
}
