// Which rows a right-click menu shows for each kind of card, and the on-screen
// clamping math for a menu. Pure. Ported from desktop/src/core/context-menu.ts.

/// What a right-clicked card is. 'video' is a movie or an episode, a series is a container.
enum MenuItemKind { album, artist, video, series, playlist, smartPlaylist, userSmartPlaylist }

/// Which context menu rows are visible.
class MenuItemVisibility {
  final bool play, playNext, playLast, shuffle, instantMix, addPlaylist, download;

  /// Download for offline listening, or remove that download (album and playlist).
  final bool offline;
  final bool favorite, markPlayed, markUnplayed, goArtist, viewDetail, rename, deleteItem, refreshMeta, editMeta;

  const MenuItemVisibility({
    this.play = false,
    this.playNext = false,
    this.playLast = false,
    this.shuffle = false,
    this.instantMix = false,
    this.addPlaylist = false,
    this.download = false,
    this.offline = false,
    this.favorite = false,
    this.markPlayed = false,
    this.markUnplayed = false,
    this.goArtist = false,
    this.viewDetail = false,
    this.rename = false,
    this.deleteItem = false,
    this.refreshMeta = false,
    this.editMeta = false,
  });

  MenuItemVisibility copyWith({
    bool? instantMix,
    bool? addPlaylist,
    bool? download,
    bool? offline,
    bool? rename,
    bool? deleteItem,
    bool? refreshMeta,
    bool? editMeta,
  }) => MenuItemVisibility(
    play: play,
    playNext: playNext,
    playLast: playLast,
    shuffle: shuffle,
    instantMix: instantMix ?? this.instantMix,
    addPlaylist: addPlaylist ?? this.addPlaylist,
    download: download ?? this.download,
    offline: offline ?? this.offline,
    favorite: favorite,
    markPlayed: markPlayed,
    markUnplayed: markUnplayed,
    goArtist: goArtist,
    viewDetail: viewDetail,
    rename: rename ?? this.rename,
    deleteItem: deleteItem ?? this.deleteItem,
    refreshMeta: refreshMeta ?? this.refreshMeta,
    editMeta: editMeta ?? this.editMeta,
  );

  Map<String, bool> toMap() => {
    'play': play,
    'playNext': playNext,
    'playLast': playLast,
    'shuffle': shuffle,
    'instantMix': instantMix,
    'addPlaylist': addPlaylist,
    'download': download,
    'offline': offline,
    'favorite': favorite,
    'markPlayed': markPlayed,
    'markUnplayed': markUnplayed,
    'goArtist': goArtist,
    'viewDetail': viewDetail,
    'rename': rename,
    'deleteItem': deleteItem,
    'refreshMeta': refreshMeta,
    'editMeta': editMeta,
  };
}

/// The rows for [kind]. [isPlayed] null means unknown, which hides both mark rows.
/// [offline] drops rows that need the server. [local] (Local mode) also drops downloads and metadata but keeps playlists.
MenuItemVisibility menuItemsForKind(MenuItemKind kind, {bool? isPlayed, bool offline = false, bool local = false}) {
  final rows = _onlineMenuItems(kind, isPlayed);
  if (local) return rows.copyWith(instantMix: false, download: false, offline: false, refreshMeta: false, editMeta: false);
  if (!offline) return rows;
  return rows.copyWith(
    instantMix: false,
    addPlaylist: false,
    download: false,
    refreshMeta: false,
    editMeta: false,
    // A smart playlist of your own is a local definition, so editing it needs no server.
    rename: kind == MenuItemKind.userSmartPlaylist && rows.rename,
    deleteItem: kind == MenuItemKind.userSmartPlaylist && rows.deleteItem,
  );
}

MenuItemVisibility _onlineMenuItems(MenuItemKind kind, bool? isPlayed) {
  switch (kind) {
    case MenuItemKind.album:
      return const MenuItemVisibility(
        play: true,
        playNext: true,
        playLast: true,
        shuffle: true,
        instantMix: true,
        addPlaylist: true,
        download: true,
        offline: true,
        favorite: true,
        goArtist: true,
        refreshMeta: true,
        editMeta: true,
      );
    case MenuItemKind.artist:
      return const MenuItemVisibility(
        play: true,
        playNext: true,
        playLast: true,
        shuffle: true,
        instantMix: true,
        addPlaylist: true,
        favorite: true,
        viewDetail: true,
      );
    case MenuItemKind.video:
      return MenuItemVisibility(play: true, viewDetail: true, markPlayed: isPlayed == false, markUnplayed: isPlayed == true);
    case MenuItemKind.series:
      return MenuItemVisibility(viewDetail: true, markPlayed: isPlayed == false, markUnplayed: isPlayed == true);
    case MenuItemKind.playlist:
      return const MenuItemVisibility(
        play: true,
        playNext: true,
        playLast: true,
        shuffle: true,
        addPlaylist: true,
        offline: true,
        rename: true,
        deleteItem: true,
      );
    case MenuItemKind.smartPlaylist:
      return const MenuItemVisibility(play: true, playNext: true, playLast: true, shuffle: true, addPlaylist: true);
    case MenuItemKind.userSmartPlaylist:
      return const MenuItemVisibility(play: true, playNext: true, playLast: true, shuffle: true, addPlaylist: true, rename: true, deleteItem: true);
  }
}

/// Nudges a menu opened at (x, y) back on screen: flips off the right or bottom edge, never below 0.
({double left, double top}) clampMenuPosition(double x, double y, double menuWidth, double menuHeight, double viewportWidth, double viewportHeight) {
  final left = x + menuWidth > viewportWidth ? x - menuWidth : x;
  final top = y + menuHeight > viewportHeight ? y - menuHeight : y;
  return (left: left < 0 ? 0 : left, top: top < 0 ? 0 : top);
}
