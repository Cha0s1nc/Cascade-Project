import SwiftUI
import CascadeKit

/// The announcements bell (AppState, "Announcements"): shown while any entry is
/// not dismissed, with a dot while any are new since the inbox was last opened.
/// In the Mac's toolbar, the iPhone's toolbar on every tab (LibraryToolbar), and
/// on tvOS a row at the top of Home, since the remote has no toolbar to reach.
struct AnnouncementsButton: View {
    @Environment(AppState.self) private var state
    @State private var open = false

    var body: some View {
        let inbox = state.announcementInbox
        if !inbox.items.isEmpty {
            Button { open = true } label: { label(unseen: inbox.unseen) }
                .help("Announcements")
                .accessibilityLabel(inbox.unseen > 0 ? "Announcements, \(inbox.unseen) new" : "Announcements")
                #if os(macOS)
                .popover(isPresented: $open, arrowEdge: .bottom) { AnnouncementsList().frame(width: 340).frame(maxHeight: 480) }
                #else
                .sheet(isPresented: $open) {
                    NavigationStack {
                        AnnouncementsList()
                            .navigationTitle("Announcements")
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { open = false } } }
                            #endif
                    }
                }
                #endif
                .onChange(of: open) { if open { state.markAnnouncementsSeen() } }
        }
    }

    @ViewBuilder
    private func label(unseen: Int) -> some View {
        #if os(tvOS)
        Label(unseen > 0 ? "Announcements: \(unseen) new" : "Announcements", systemImage: "bell")
        #else
        Image(systemName: "bell")
            .overlay(alignment: .topTrailing) {
                if unseen > 0 { Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 3, y: -2) }
            }
        #endif
    }
}

/// The inbox: each entry with its badge, date and who it is from, dismissed one
/// at a time or all at once. Text only.
struct AnnouncementsList: View {
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL

    var body: some View {
        let items = state.announcementInbox.items
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(items) { card($0) }
                if items.isEmpty {
                    Text("Nothing here.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Spacer()
                        Button("Clear all") { state.dismissAnnouncements(items.map(\.id)) }
                    }
                }
            }
            .padding()
        }
    }

    private func card(_ a: Announcement) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(a.title).font(.headline)
                Spacer(minLength: 8)
                Button { state.dismissAnnouncements([a.id]) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    #if !os(tvOS)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    #endif
                    .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 6) {
                AnnouncementBadge(kind: a.kind)
                Text([Self.day(a.date), a.source].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !a.body.isEmpty {
                Text(a.body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // tvOS has no browser to open a link in.
            #if !os(tvOS)
            if let link = a.link {
                Button("Read more") { openURL(link) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
            }
            #endif
        }
        .accessibilityElement(children: .contain)
    }

    private static func day(_ ymd: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: ymd)?.formatted(date: .long, time: .omitted) ?? ymd
    }
}

/// Official for the Cascade project's own posts, Server for a server's. Drawn
/// from where the entry was read (Announcement.kind), never from its text.
struct AnnouncementBadge: View {
    let kind: Announcement.Kind

    var body: some View {
        Text(kind == .official ? "OFFICIAL" : "SERVER")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(kind == .official ? Color.white : Color.secondary)
            .background(kind == .official ? Color.accentColor : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }
}
