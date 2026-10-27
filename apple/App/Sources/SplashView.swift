import SwiftUI

/// Launch splash, the desktop's (desktop/styles/splash.css): the logo pops in,
/// clicks, and "Cascade" slides out to the left from under it. RootView lays
/// it over the app and removes it when `done` fires.
///
/// ponytail: a fixed floor rather than covering the load as the desktop does.
/// restore() is synchronous here, so there is nothing to wait for at launch;
/// the views show their own loading states.
struct SplashView: View {
    /// Once per process: a second Mac window or iPad scene opens straight in.
    @MainActor static var played = false

    let signInShowing: Bool
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var logoIn = false
    @State private var logoScale: CGFloat = 0.8
    @State private var nameOut = false
    @State private var nameWidth: CGFloat = 0

    #if os(tvOS)
    private let unit: CGFloat = 2
    #else
    private let unit: CGFloat = 1
    #endif

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            HStack(spacing: 0) {
                Text("Cascade")
                    .font(.system(size: 44 * unit, weight: .bold))
                    .tracking(-0.9 * unit)
                    .fixedSize()
                    .padding(.trailing, 18 * unit)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
                    // The width grows so the pair re-centers as the name comes out:
                    // the logo drifts right while the name slides left from behind it.
                    .frame(width: nameOut ? nameWidth : 0, alignment: .leading)
                    .clipped()
                    .offset(x: nameOut ? 0 : 60 * unit)
                    .opacity(nameOut ? 1 : 0)
                logo
                    .zIndex(1)
                    .opacity(logoIn ? 1 : 0)
                    .scaleEffect(logoScale)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: done)
        .task { await play() }
    }

    private var logo: some View {
        Group {
            // shared/assets/linux-icons/512x512.png, a bundle resource (project.yml).
            if let image = PlatformImage(named: "512x512") {
                #if os(macOS)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            }
        }
        .frame(width: 96 * unit, height: 96 * unit)
        .clipShape(RoundedRectangle(cornerRadius: 22 * unit, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 20 * unit, y: 10 * unit)
    }

    private var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        colorScheme == .dark ? .black : .white
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Same beats as splash.css: in at 0, click at 0.45s, name out at 0.65s
    /// and done by 1.15s, then held until the floor.
    private func play() async {
        Self.played = true
        let floor: Duration = signInShowing ? .seconds(2) : .milliseconds(1300)
        if reduceMotion {
            logoIn = true; logoScale = 1; nameOut = true
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { logoIn = true; logoScale = 1 }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeIn(duration: 0.1)) { logoScale = 0.88 }
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { logoScale = 1 }
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)) { nameOut = true }
            try? await Task.sleep(for: .milliseconds(650))
        }
        try? await Task.sleep(for: reduceMotion ? floor : floor - .milliseconds(1300))
        done()
    }
}
