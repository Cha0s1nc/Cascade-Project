import Foundation

/// One line of what the app is doing, in debug builds only. Prefixed so it is
/// easy to pick out of Xcode's console or of
/// `xcrun devicectl device process launch --console`, both of which show
/// stdout from a phone; nothing is logged in a release build.
public func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Cascade] \(message())")
    // stdout is block-buffered when it is a pipe rather than a terminal, which
    // is what devicectl's --console gives it: without this, lines sat in the
    // buffer until 4 KB of them piled up.
    fflush(stdout)
    #endif
}
