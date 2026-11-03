import Foundation

// #134 (server v1.43) — the `/api/auth/me` half of "Support-Info kopieren":
// time zone, the modules that are on, every AI capability with its reason and
// the usage level. Read from what the app already loaded (`SettingsStore`,
// `ModuleGate`, `AICapabilityGate`); nothing here asks the server again.
//
// Same rule as the rest of the report: every server string is checked against
// a narrow shape before it is printed, so a name, an address or a value can
// never ride in on a field.

extension SupportInfoReport {
    static func accountLines(_ input: Input) -> [String] {
        var lines = ["time zone: \(zone(input.timeZone) ?? "unknown")"]
        lines.append(modulesLine(input.modules))
        lines += aiLines(input.ai)
        return lines
    }

    /// The modules that are on, sorted; the ones that are off are implied.
    static func modulesLine(_ modules: [String: Bool]?) -> String {
        guard let modules else { return "modules: not loaded" }
        let on = modules.filter(\.value).keys.compactMap(code).sorted()
        return on.isEmpty ? "modules on: none" : "modules on: \(on.joined(separator: ", "))"
    }

    /// One line per AI capability in the server's order of the keys, then the
    /// usage level. A capability the block leaves out reads "not reported".
    static func aiLines(_ ai: AIAccountBlock?) -> [String] {
        guard let ai else { return ["ai: not reported"] }
        var lines = ["ai usage level: \(ai.usage.map(\.level.rawValue) ?? "not reported")"]
        for key in AICapabilityKey.allCases {
            guard let state = ai.capabilities[key] else {
                lines.append("ai \(key.rawValue): not reported")
                continue
            }
            if state.available {
                lines.append("ai \(key.rawValue): available")
            } else {
                let reason = state.reason.flatMap { $0 == .unknown ? nil : code($0.rawValue) } ?? "unknown"
                lines.append("ai \(key.rawValue): unavailable (\(reason))")
            }
        }
        return lines
    }

    /// An IANA zone this device knows (`Europe/Berlin`), else `nil`.
    static func zone(_ value: String?) -> String? {
        guard let value, (1 ... 64).contains(value.count), TimeZone(identifier: value) != nil,
              isPlain(value, extra: "/_+-") else { return nil }
        return value
    }

    /// A machine key or reason (`illness`, `operator_disabled`): letters,
    /// digits, `.`, `_`, `-`, at most 40 characters.
    static func code(_ value: String) -> String? {
        guard (1 ... 40).contains(value.count), isPlain(value, extra: "._-") else { return nil }
        return value
    }

    /// ASCII letters and digits plus the `extra` characters, nothing else.
    private static func isPlain(_ value: String, extra: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || extra.unicodeScalars.contains(scalar))
        }
    }
}
