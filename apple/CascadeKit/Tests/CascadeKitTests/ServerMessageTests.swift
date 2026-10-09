import Testing
@testable import CascadeKit

// The desktop's test/server-messages.test.ts cases.
struct ServerMessageTests {
    @Test func aDashboardMessageReadsItsParts() {
        let m = ServerMessage.parse(["Header": "Maintenance", "Text": "Restarting at 2", "TimeoutMs": "5000"])
        #expect(m == ServerMessage(header: "Maintenance", text: "Restarting at 2", timeout: 5))
        #expect(ServerMessage.parse(["Text": "hi"]) == ServerMessage(header: "Message from your server", text: "hi", timeout: nil))
        #expect(ServerMessage.parse([:]) == nil)
        #expect(ServerMessage.parse(["Header": "x", "TimeoutMs": "soon"])?.timeout == nil)
    }

    @Test func theDisclaimerComesOutAsPlainText() {
        #expect(ServerMessage.loginDisclaimerText("<p>Welcome to <b>Chaos</b> &amp; friends.</p><p>Be nice.<br>Thanks</p>")
                == "Welcome to Chaos & friends.\nBe nice.\nThanks")
        #expect(ServerMessage.loginDisclaimerText("<script>alert(1)</script>ok") == "alert(1)ok")
        #expect(ServerMessage.loginDisclaimerText(nil) == "")
        #expect(ServerMessage.loginDisclaimerText("caf&#233; &#x2014;") == "café —")
    }

    @Test func dashboardMessagesArriveAsACommand() {
        let json: [String: Any] = ["MessageType": "GeneralCommand",
                                   "Data": ["Name": "DisplayMessage", "Arguments": ["Header": "Hi", "Text": "There"]]]
        #expect(RemoteCommand.parse(json) == .message(ServerMessage(header: "Hi", text: "There", timeout: nil)))
        #expect(RemoteControl.supportedCommands.contains("DisplayMessage"))
        // A room or a cast gates playback, never a note for the person.
        #expect(RemoteControl.accepts(.message(ServerMessage(header: "a", text: "", timeout: nil)), in: { var s = OwnershipState(); s.waterfallActive = true; return s }()))
    }
}
