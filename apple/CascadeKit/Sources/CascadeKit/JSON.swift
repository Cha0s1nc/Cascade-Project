import Foundation

// Jellyfin's JSON is PascalCase throughout ("ItemId", "PlaySessionId"). Swift
// properties are lowerCamelCase, and the language will not even let a member be
// called `Type` or `Protocol`, which are two of the fields this app reads most.
//
// So rather than a CodingKeys block on every model - which is where key-mapping
// bugs live, and which is a lot of lines to keep in step with a spec - the
// whole difference is one rule applied by these two coders: flip the case of
// the first character. Every model in this package uses natural Swift names and
// no CodingKeys, and anything that needs a name the rule cannot produce (there
// is nothing so far) declares CodingKeys for itself.
//
// Use `JSON.decoder` and `JSON.encoder`, never a bare JSONDecoder().

private struct PascalKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

private func flipFirst(_ key: String, uppercase: Bool) -> String {
    guard let first = key.first else { return key }
    let flipped = uppercase ? first.uppercased() : first.lowercased()
    return flipped + key.dropFirst()
}

public enum JSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            PascalKey(stringValue: flipFirst(path.last!.stringValue, uppercase: false))
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .custom { path in
            PascalKey(stringValue: flipFirst(path.last!.stringValue, uppercase: true))
        }
        return e
    }()
}
