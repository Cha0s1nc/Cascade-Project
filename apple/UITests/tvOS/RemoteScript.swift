import XCTest

/// Drives the tvOS app with the Siri Remote from a script, so the TV app can be
/// tested without a person at the simulator. `simctl` has no way to press
/// remote buttons; XCUIRemote does.
///
/// Everything comes from the environment. xcodebuild forwards any variable
/// prefixed TEST_RUNNER_ with the prefix removed:
///
///     TEST_RUNNER_SCRIPT='right,right,select,wait:2,shot:album' \
///     TEST_RUNNER_APP_ARGS='-cascade.serverUrl http://127.0.0.1:8096' \
///     xcodebuild test -scheme CascadetvOS -destination 'platform=tvOS Simulator,name=Apple TV' \
///       -only-testing:CascadetvOSUITests/RemoteScript/testScript
///
/// SCRIPT is comma separated:
///   up down left right select menu playpause home   press that button
///   hold:select                                      long-press it
///   wait:1.5                                         seconds
///   shot:name                                        screenshot, kept in the
///                                                    result bundle as `name`,
///                                                    and as OUT_DIR/name.png
///   qc                                               approve the Quick Connect
///                                                    code on screen (needs
///                                                    JF_URL and JF_ADMIN_TOKEN)
///   tree:name                                        the accessibility tree,
///                                                    kept as text
/// After every button press the script waits 0.6 s for focus to settle.
final class RemoteScript: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    func testScript() async throws {
        let app = XCUIApplication()
        app.launchArguments = (env["APP_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()
        let remote = XCUIRemote.shared
        let buttons: [String: XCUIRemote.Button] = [
            "up": .up, "down": .down, "left": .left, "right": .right,
            "select": .select, "menu": .menu, "playpause": .playPause, "home": .home,
        ]

        for step in (env["SCRIPT"] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "wait":
                try await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "shot":
                let screenshot = XCUIScreen.main.screenshot()
                let shot = XCTAttachment(screenshot: screenshot)
                shot.name = arg
                shot.lifetime = .keepAlways
                add(shot)
                // Also straight to disk when OUT_DIR is set: the result
                // bundle is only complete once xcodebuild exits, and
                // xcodebuild sometimes hangs after a finished test.
                if let dir = env["OUT_DIR"] {
                    try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).png"))
                }
            case "tree":
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = arg
                tree.lifetime = .keepAlways
                add(tree)
                if let dir = env["OUT_DIR"] {
                    try app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).txt"), atomically: true, encoding: .utf8)
                }
            case "hold":
                let button = try XCTUnwrap(buttons[arg], "unknown button \(arg)")
                remote.press(button, forDuration: 1.2)
                try await Task.sleep(for: .seconds(0.6))
            case "qc":
                try await approveQuickConnect(app)
            default:
                let button = try XCTUnwrap(buttons[parts[0]], "unknown step \(step)")
                remote.press(button)
                try await Task.sleep(for: .seconds(0.6))
            }
        }
    }

    /// Reads the code off the sign-in screen and authorizes it as the admin
    /// user, which is what a person does on another device.
    @MainActor
    private func approveQuickConnect(_ app: XCUIApplication) async throws {
        let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Quick Connect code'")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 20), "no Quick Connect code on screen")
        let code = label.label.filter(\.isNumber)
        let server = try XCTUnwrap(env["JF_URL"]), token = try XCTUnwrap(env["JF_ADMIN_TOKEN"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(server)/QuickConnect/Authorize?code=\(code)")))
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Client=\"UITest\", Device=\"UITest\", DeviceId=\"uitest\", Version=\"1\", Token=\"\(token)\"",
                         forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Quick Connect approval refused")
    }
}
