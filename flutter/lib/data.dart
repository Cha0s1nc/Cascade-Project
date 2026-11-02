// Mock library for the prototype. Nothing here talks to Jellyfin yet: the
// covers are gradients, the same placeholders the Figma draft uses.
import 'package:flutter/material.dart';

class Song {
  const Song(this.title, this.artist, this.album, this.year, this.seconds, this.art);
  final String title, artist, album;
  final int year, seconds;
  final List<Color> art;
}

class Album {
  const Album(this.title, this.subtitle, this.art);
  final String title, subtitle;
  final List<Color> art;
}

class Video {
  const Video(this.title, this.episode, this.left, this.progress, this.art);
  final String title, episode, left;
  final double progress;
  final List<Color> art;
}

const inRainbows = [Color(0xFFFFD166), Color(0xFFEF476F), Color(0xFF26547C)];

const reckoner = Song('Reckoner', 'Radiohead', 'In Rainbows', 2007, 290, inRainbows);
const weirdFishes = Song('Weird Fishes / Arpeggi', 'Radiohead', 'In Rainbows', 2007, 318, inRainbows);

const recentlyPlayed = [
  Song('Nights', 'Frank Ocean', 'Blonde', 2016, 307, [Color(0xFFE8E4DC), Color(0xFFA3B18A), Color(0xFF3A5A40)]),
  Song('Instant Crush', 'Daft Punk', 'Random Access Memories', 2013, 337, [Color(0xFFD4B483), Color(0xFF3D3D3D), Color(0xFF0D0D0D)]),
  Song('Let It Happen', 'Tame Impala', 'Currents', 2015, 467, [Color(0xFFFF7B00), Color(0xFFC2185B), Color(0xFF311B92)]),
  Song('Kyoto', 'Phoebe Bridgers', 'Punisher', 2020, 184, [Color(0xFF6C2A8C), Color(0xFFD76D77), Color(0xFF1A1A2E)]),
  Song('Seventeen', 'Sharon Van Etten', 'Remind Me Tomorrow', 2019, 285, [Color(0xFF0F2027), Color(0xFF2C5364), Color(0xFF7CC4FF)]),
  Song('Running Up That Hill', 'Kate Bush', 'Hounds of Love', 1985, 300, [Color(0xFF5F2C82), Color(0xFF49A09D), Color(0xFF16222A)]),
  Song('Snooze', 'SZA', 'SOS', 2022, 201, [Color(0xFF6DD5ED), Color(0xFF2193B0), Color(0xFF0B3D5C)]),
  Song('Earfquake', 'Tyler, The Creator', 'Igor', 2019, 190, [Color(0xFFFFB3C6), Color(0xFFFF8FAB), Color(0xFFFB6F92)]),
];

const recentlyAdded = [
  Album('Melodrama', 'Lorde', [Color(0xFF2B2D6E), Color(0xFFC33764), Color(0xFFF8B195)]),
  Album('Carrie & Lowell', 'Sufjan Stevens', [Color(0xFFC9B79C), Color(0xFF8D7B68), Color(0xFF4A3F35)]),
  Album('Renaissance', 'Beyoncé', [Color(0xFFE0E0E0), Color(0xFF9E9E9E), Color(0xFF212121)]),
  Album('Titanic Rising', 'Weyes Blood', [Color(0xFF89C2D9), Color(0xFF2A6F97), Color(0xFF012A4A)]),
  Album('Blue Rev', 'Alvvays', [Color(0xFF4FACFE), Color(0xFF00C6D4), Color(0xFFC8A2F0)]),
  Album('Heaven or Las Vegas', 'Cocteau Twins', [Color(0xFFFF9A8B), Color(0xFFFF6A88), Color(0xFF7A2E4D)]),
  Album('Ants From Up There', 'Black Country, New Road', [Color(0xFFF6D365), Color(0xFFFDA085), Color(0xFF6B4226)]),
  Album('Fetch the Bolt Cutters', 'Fiona Apple', [Color(0xFFF9D423), Color(0xFFFF4E50), Color(0xFF2D1B1B)]),
];

const recentPlaylists = [
  Album('Late Night Drive', '42 songs', [Color(0xFF0F2027), Color(0xFF2C5364), Color(0xFF7CC4FF)]),
  Album('Favorites', '318 songs', [Color(0xFFFF6B8A), Color(0xFFC9184A), Color(0xFF590D22)]),
  Album('Most Played', 'Smart playlist', [Color(0xFF4ADE80), Color(0xFF16A34A), Color(0xFF052E16)]),
  Album('Road Trip', '64 songs', [Color(0xFFF6D365), Color(0xFFFDA085), Color(0xFF6B4226)]),
];

const continueWatching = [
  Video('Severance', 'S2 E6 · Attila', '23 min left', 0.62, [Color(0xFFA8C0D6), Color(0xFF3D5A80), Color(0xFF0B132B)]),
  Video('Dune: Part Two', 'Movie · 2024', '1 h 12 min left', 0.31, [Color(0xFFF4A259), Color(0xFFBC4B51), Color(0xFF2B1B17)]),
  Video('The Bear', 'S3 E2 · Next episode', 'Up next', 0, [Color(0xFF3A3A3A), Color(0xFF1D3557), Color(0xFFE63946)]),
];
