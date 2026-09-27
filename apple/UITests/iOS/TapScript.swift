import XCTest

/// Drives the iOS app from a script, the phone's counterpart of the tvOS
/// RemoteScript: `simctl` can screenshot a simulator but cannot tap one.
///
/// Everything comes from the environment. xcodebuild forwards any variable
/// prefixed TEST_RUNNER_ with the prefix removed:
///
///     TEST_RUNNER_SCRIPT='tap:Songs,wait:1,press:Blocks Track 1,shot:menu' \
///     TEST_RUNNER_OUT_DIR=/tmp/shots \
///     xcodebuild test -scheme CascadeiOS -destination 'id=<udid>' \
///       -only-testing:CascadeiOSUITests/TapScript/testScript
///
/// SCRIPT is separated by `|` (labels can contain commas):
///   tap:text        tap the first element whose identifier or label is text
///   press:text      long-press it (opens a context menu)
///   tapat:x,y       tap at a point, as fractions of the screen (0-1)
///   drag:a>b        drag element a onto element b (reorder handles)
///   dragat:x,y>x,y  drag between two points, as fractions of the screen
///   swipeup / swipedown / swipeleft / swiperight   on the app, or
///                   swipeleft:text on one element (swipe to delete)
///   type:text       type into whatever has focus
///   lock            press the side button (the lock screen)
///   home            press home
///   controlcenter   pull down Control Center
///   sbtree:name     SpringBoard's accessibility tree (lock screen, Control Center)
///   wait:1.5        seconds
///   shot:name       screenshot to OUT_DIR/name.png
///   tree:name       the accessibility tree to OUT_DIR/name.txt
///   qc              approve the Quick Connect code on screen (JF_URL, JF_ADMIN_TOKEN)
///   launch          relaunch the app with APP_ARGS
final class TapScript: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    @MainActor
    func testScript() async throws {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = (env["APP_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()

        for step in (env["SCRIPT"] ?? "").split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "tap":
                try find(app, arg).tap()
            case "press":
                try find(app, arg).press(forDuration: 1.2)
            case "tapat":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: CGVector(dx: xy[0], dy: xy[1])).tap()
            case "drag":
                let ends = arg.split(separator: ">").map(String.init)
                let from = try find(app, ends[0]), to = try find(app, ends[1])
                from.press(forDuration: 1.0, thenDragTo: to)
            case "dragat":
                let ends = arg.split(separator: ">").map { $0.split(separator: ",").compactMap { Double($0) } }
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: ends[0][0], dy: ends[0][1]))
                let to = app.coordinate(withNormalizedOffset: CGVector(dx: ends[1][0], dy: ends[1][1]))
                from.press(forDuration: 1.0, thenDragTo: to)
            case "swipeup": try (arg.isEmpty ? app : find(app, arg)).swipeUp()
            case "swipedown": try (arg.isEmpty ? app : find(app, arg)).swipeDown()
            case "swipeleft": try (arg.isEmpty ? app : find(app, arg)).swipeLeft()
            case "swiperight": try (arg.isEmpty ? app : find(app, arg)).swipeRight()
            case "type": app.typeText(arg)
            case "lock":
                // No public API for the side button. This selector is what
                // XCTest itself uses, and it only has to work in a simulator.
                XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
            case "home": XCUIDevice.shared.press(.home)
            case "controlcenter":
                let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.005))
                top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)))
            case "sbtree":
                if let dir = env["OUT_DIR"] {
                    try springboard.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).txt"),
                                                           atomically: true, encoding: .utf8)
                }
            case "launch": app.launch()
            case "wait":
                try await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "shot":
                if let dir = env["OUT_DIR"] {
                    try XCUIScreen.main.screenshot().pngRepresentation
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).png"))
                }
            case "tree":
                if let dir = env["OUT_DIR"] {
                    try app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).txt"),
                                                   atomically: true, encoding: .utf8)
                }
            case "qc":
                try await approveQuickConnect(app)
            default:
                XCTFail("unknown step \(step)")
            }
            // Let animations settle so the next step finds what it expects.
            try await Task.sleep(for: .seconds(0.5))
        }
    }

    @MainActor
    private func find(_ app: XCUIApplication, _ text: String) throws -> XCUIElement {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", text, text)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10), "nothing on screen called \(text)")
        return match
    }

    @MainActor
    private func approveQuickConnect(_ app: XCUIApplication) async throws {
        let label = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]{6}'")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 20), "no Quick Connect code on screen")
        let server = try XCTUnwrap(env["JF_URL"]), token = try XCTUnwrap(env["JF_ADMIN_TOKEN"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(server)/QuickConnect/Authorize?code=\(label.label)")))
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Client=\"UITest\", Device=\"UITest\", DeviceId=\"uitest-ios\", Version=\"1\", Token=\"\(token)\"",
                         forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Quick Connect approval refused")
    }
}
