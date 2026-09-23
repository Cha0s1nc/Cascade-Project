import SwiftUI
import CascadeKit

/// Loads the current track's lyrics from the server's Cascade plugin, for the
/// Now Playing screen. Views read `lines`; nil while loading or when the track
/// has none.
@MainActor
@Observable
final class LyricsModel {
    private(set) var lines: [LyricLine]?
    /// Track and route last loaded. The route is part of it because the plugin
    /// probe can finish after Now Playing opens, and then it is worth asking.
    private var loadedKey: String?

    func load(itemId: String?, client: JellyfinClient?, api: CascadePluginApi?) async {
        let key = "\(itemId ?? "")|\(String(describing: api))"
        guard key != loadedKey else { return }
        lines = nil
        loadedKey = key
        guard let itemId, let client, let api else { return }
        let fetched = try? await client.serverLyrics(itemId: itemId, api: api)
        // A newer track may have started while this one was in flight.
        if loadedKey == key { lines = fetched }
    }
}

/// Line-synced lyrics: the active line bright, the rest dimmed, scrolled to
/// keep the active one near the top. On iOS a tap seeks to that line.
/// Word-level (karaoke) fill is not drawn yet; karaoke files still show and
/// sync by line.
struct LyricsView: View {
    let lines: [LyricLine]
    let player: PlaybackService

    private var activeIndex: Int? {
        Lyrics.activeLineIndex(lines, at: Int(player.positionSeconds * Double(Lyrics.ticksPerSecond)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: lineSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(lineFont)
                            .foregroundStyle(index == activeIndex ? Color.primary : Color.secondary.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            #if !os(tvOS)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await player.seek(to: Double(line.start) / Double(Lyrics.ticksPerSecond)) }
                            }
                            #endif
                    }
                }
                .padding(.vertical, 40)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
        }
    }

    private var lineFont: Font {
        #if os(tvOS)
        .system(size: 38, weight: .bold)
        #else
        .title2.bold()
        #endif
    }

    private var lineSpacing: CGFloat {
        #if os(tvOS)
        28
        #else
        18
        #endif
    }
}
