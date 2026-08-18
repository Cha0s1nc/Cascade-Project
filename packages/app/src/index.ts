// Everything the Cascade apps share below the UI: talking to Jellyfin, holding
// a session, playing audio, syncing a room, answering a remote, finding lyrics
// and colours.
//
// Almost nothing here renders. The two apps (apps/tv and apps/mobile) own their
// own screens and components, because a 10-foot D-pad UI and a phone UI have
// almost nothing useful to share at that level - and everything below it.
//
// The one exception is GlassSurface, which is a platform capability wrapper
// rather than layout: both apps need identical "use Liquid Glass if this OS has
// it, otherwise fill with this colour" logic, and getting that wrong in one of
// them means a bar with no background at all on Android.

export * from './tokens.ts';
export * from './platform/index.ts';
export * from './api/client.ts';
export * from './api/hooks.ts';
export * from './auth/session.ts';
export * from './playback/PlaybackService.ts';
export * from './waterfall/WaterfallService.ts';
export * from './remote/remote.ts';
export * from './lyrics/kugou.ts';
export * from './art/palette.ts';
export * from './ui/GlassSurface.tsx';
export * from './ui/SearchGlyph.tsx';
