import SwiftUI
import CascadeKit

/// Who added queue entry `index` in a Waterfall room, or nil. WaterfallSession keeps that
/// list private (agent L2's file), so this is the one seam to wire at merge: return
/// `session.addedBy(at: index)` once it has a public reader.
@MainActor
func queueAddedBy(_ session: WaterfallSession?, index: Int) -> String? { nil }

/// What a row being dragged carries: its place in the queue, as text a drop on another row reads
/// back (so dropping it into a text field pastes something harmless).
private struct QueueDrag: Transferable {
    var index: Int

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { "cascade-queue:\($0.index)" },
                            importing: { text in
            guard text.hasPrefix("cascade-queue:"), let i = Int(text.dropFirst("cascade-queue:".count)) else {
                throw CocoaError(.coderInvalidValue)
            }
            return QueueDrag(index: i)
        })
    }
}

/// The overlay's queue: History (collapsed), the current track pinned, then Up Next, as the
/// desktop's three parts rather than one list scrolled to the middle. Rows are drawn lazily, so a
/// ten-thousand-song queue costs what the screen shows. A Waterfall guest mirrors the host's
/// queue, so for one the drag handles and remove buttons are not there at all.
struct QueuePanel: View {
    let player: PlaybackService
    @Environment(AppState.self) private var state
    private var ui: MacNowPlayingUI { .shared }

    private var follower: Bool { state.waterfall?.role == .guest }
    private var inRoom: Bool { state.waterfall?.isActive == true }
    private var index: Int { player.queue.index }
    private var items: [JfItem] { player.queue.items }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QUEUE").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Button { player.autoMix.toggle() } label: {
                    Text("\u{221E}").font(.system(size: 17, weight: .bold))
                        .frame(width: 28, height: 24)
                        .background(Capsule().fill(player.autoMix ? MacTheme.shared.accent.opacity(0.3) : .clear))
                }
                .buttonStyle(.hover)
                .foregroundStyle(player.autoMix ? MacTheme.shared.accent : .secondary)
                .help("Auto-mix similar tracks when the queue ends")
                .accessibilityLabel("Auto-mix")
                .accessibilityValue(player.autoMix ? "On" : "Off")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if index > 0 { history }
                    Section {
                        upNextHead
                        if index + 1 >= items.count {
                            Text(items.isEmpty ? "Queue is empty" : "Nothing up next")
                                .foregroundStyle(.secondary).padding(20)
                        } else {
                            ForEach((index + 1)..<items.count, id: \.self) { i in
                                QueueRow(player: player, index: i, item: items[i], editable: !follower,
                                         addedBy: queueAddedBy(state.waterfall, index: i))
                            }
                        }
                        if player.hasMoreQueue {
                            Button {
                                Task { await player.loadMoreQueue() }
                            } label: {
                                Label(player.isLoadingMoreQueue ? "Adding\u{2026}" : "Add Next \(PlaybackService.queuePageSize) Songs",
                                      systemImage: "text.badge.plus")
                            }
                            .disabled(player.isLoadingMoreQueue)
                            .padding(12)
                        }
                    } header: {
                        nowPlaying
                    }
                }
            }
        }
    }

    // MARK: Parts

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.15)) { ui.historyOpen.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(ui.historyOpen ? 90 : 0))
                        Text("History").font(.subheadline.weight(.semibold))
                        Text("\(index)").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(ui.historyOpen ? "Expanded" : "Collapsed")
                Spacer()
                // Positions in a Waterfall room are shared, so the history is not this
                // client's to clear there.
                if !inRoom {
                    Button("Clear") {
                        player.removeQueueItems(at: IndexSet(0..<index))
                        ui.historyOpen = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            if ui.historyOpen {
                // Not windowed beyond the lazy stack: the rows are cheap until shown.
                ForEach(0..<index, id: \.self) { i in
                    QueueRow(player: player, index: i, item: items[i], editable: false,
                             addedBy: queueAddedBy(state.waterfall, index: i))
                }
            }
        }
    }

    /// The pinned Now Playing row. In the section header, so it stays up while Up Next scrolls.
    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOW PLAYING").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 8)
            if items.indices.contains(index) {
                QueueRow(player: player, index: index, item: items[index], current: true, editable: false,
                         addedBy: queueAddedBy(state.waterfall, index: index))
            } else {
                Text("Nothing playing").foregroundStyle(.secondary).padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private var upNextHead: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("UP NEXT").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                if let source = QueueMeta.sourceFallback(items) {
                    Text("From \(source)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // The end time moves while paused, so it is refreshed on a timer; with repeat or
            // auto-mix on there is no end.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(QueueMeta.summary(queue: items, index: index, position: player.positionSeconds,
                                       repeating: player.repeatMode != .none, autoMix: player.autoMix))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// One queue row: handle, cover, title and artist (and "added by"), length, remove.
private struct QueueRow: View {
    let player: PlaybackService
    let index: Int
    let item: JfItem
    var current = false
    let editable: Bool
    let addedBy: String?

    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 10) {
            if editable {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .contentShape(Rectangle())
                    .draggable(QueueDrag(index: index))
                    .help("Drag to reorder")
                    .accessibilityLabel("Reorder")
            }
            ArtworkView(itemId: item.albumId ?? item.id, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if current { PlayingIndicator(itemId: item.id) }
                    Text(item.name ?? "Unknown").lineLimit(1).fontWeight(current ? .semibold : .regular)
                }
                HStack(spacing: 6) {
                    Text(item.albumArtist ?? item.artists?.first ?? "").lineLimit(1)
                    if let addedBy { Text("added by \(addedBy)").italic().lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(clock(seconds(fromTicks: item.runTimeTicks ?? 0)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if editable {
                Button {
                    player.removeQueueItems(at: IndexSet(integer: index))
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hover)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove from queue")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(current ? MacTheme.shared.accent.opacity(0.15) : (hovering ? Color.primary.opacity(0.06) : .clear))
        .overlay(alignment: .top) {
            Rectangle().fill(MacTheme.shared.accent).frame(height: 2).opacity(dropTarget ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // A guest's jump goes through the transport gate, which hands it to the host.
            if !current { Task { await player.jump(to: index) } }
        }
        .trackContextMenu(item)
        .modifier(DropOnRow(player: player, index: index, enabled: editable, targeted: $dropTarget))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : .isButton)
    }
}

/// Dropping a dragged row on this one puts it here: it ends up at this row's place.
private struct DropOnRow: ViewModifier {
    let player: PlaybackService
    let index: Int
    let enabled: Bool
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: QueueDrag.self) { drops, _ in
                guard let from = drops.first?.index, from != index else { return false }
                // onMove's destination is an offset before the move: past the row when moving
                // down, so the row lands where this one was.
                player.moveQueueItems(from: IndexSet(integer: from), to: from < index ? index + 1 : index)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}
