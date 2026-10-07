import SwiftUI

// UIImage on iOS and tvOS, NSImage on the Mac. Shared views go through these
// few names so they stop branching on UIKit at every call site.

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) }
    /// Pixel area, for NSCache costs. NSImage has no scale; its reps carry the pixels.
    var pixelArea: Int { cgImage.map { $0.width * $0.height } ?? Int(size.width * size.height) }
    /// AppKit decodes lazily at first draw; forcing a CGImage here moves that
    /// off the main thread, as byPreparingForDisplay does on iOS.
    func preparedForDisplay() async -> NSImage? { cgImage == nil ? nil : self }
}

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
typealias PlatformImage = UIImage

extension UIImage {
    var pixelArea: Int { Int(size.width * size.height * scale * scale) }
    func preparedForDisplay() async -> UIImage? { await byPreparingForDisplay() }
}

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif

extension View {
    /// Inline navigation titles, where the platform has them.
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// No automatic capitals in a field, where the platform does that at all.
    @ViewBuilder func noAutocaps() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }
}
