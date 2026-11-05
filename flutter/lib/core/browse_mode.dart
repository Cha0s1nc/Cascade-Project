// The Music / Video mode choice. Ported from desktop/src/core/browse-mode.ts.
// sectionMode lives in nav.dart already.

/// The saved mode resolved against whether a video library exists. No video library always means 'music'.
String resolveBrowseMode(String? saved, bool hasVideoLibrary) => hasVideoLibrary && saved == 'video' ? 'video' : 'music';
