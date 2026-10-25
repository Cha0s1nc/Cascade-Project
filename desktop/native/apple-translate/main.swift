// Cascade's bridge to Apple's on-device Translation framework (macOS 26+).
//
// A long-lived helper that main.js spawns on first use. It reads one JSON
// request per line on stdin and writes one JSON response per line on stdout,
// rather than taking lyrics as arguments: lyrics carry quotes, newlines and
// emoji, and a long sheet would run into the argument length limit.
//
//   {"id":1,"op":"availability","languages":["ja","ko"]}
//     -> {"id":1,"status":{"ja":"installed","ko":"supported"}}
//   {"id":2,"op":"translate","source":"ja","text":"..."}
//     -> {"id":2,"text":"..."}   or   {"id":2,"error":"..."}
//
// Always into English. "installed" means the language pair is on this Mac and
// translates with no network; "supported" means macOS could translate it once
// the user installs the language in System Settings, which a windowless helper
// cannot do for them; "unsupported" means Apple has no model for it at all.
//
// TranslationSession(installedSource:target:) is the macOS 26 API that works
// with no SwiftUI view, and only for installed pairs - which is exactly the
// case this helper is ever asked to translate.

import Foundation
import Translation

@main
struct AppleTranslate {
  static func main() async {
    let english = Locale.Language(identifier: "en")
    let availability = LanguageAvailability()
    // One session per source language, kept for the life of the process so
    // the model loads once per sheet rather than once per line.
    var sessions: [String: TranslationSession] = [:]

    do {
      for try await line in FileHandle.standardInput.bytes.lines {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] else { continue }
        var response: [String: Any] = ["id": id]

        switch request["op"] as? String {
        case "availability":
          var status: [String: String] = [:]
          for code in (request["languages"] as? [String]) ?? [] {
            switch await availability.status(from: Locale.Language(identifier: code), to: english) {
            case .installed: status[code] = "installed"
            case .supported: status[code] = "supported"
            case .unsupported: status[code] = "unsupported"
            @unknown default: status[code] = "unsupported"
            }
          }
          response["status"] = status

        case "translate":
          guard let source = request["source"] as? String, let text = request["text"] as? String else {
            response["error"] = "translate needs source and text"
            break
          }
          do {
            let session = sessions[source]
              ?? TranslationSession(installedSource: Locale.Language(identifier: source), target: english)
            sessions[source] = session
            response["text"] = try await session.translate(text).targetText
          } catch {
            // Drop the session so the next request starts clean, e.g. after
            // the language was removed from macOS while Cascade was running.
            sessions[source] = nil
            response["error"] = String(describing: error)
          }

        default:
          response["error"] = "unknown op"
        }

        if let out = try? JSONSerialization.data(withJSONObject: response),
           let json = String(data: out, encoding: .utf8) {
          print(json)
          fflush(stdout)
        }
      }
    } catch {
      // stdin closed or unreadable: main.js is gone, so exit quietly.
    }
  }
}
