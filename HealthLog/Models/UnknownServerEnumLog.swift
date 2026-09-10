import Foundation
import Synchronization

/// Audit B-4 — logs each unrecognised server enum token **once per process**.
///
/// One shared register for the enums W3b made tolerant (mood level, nutrient
/// code, injection site, container type, schedule type, side-effect entry).
/// A page full of one new token would otherwise write one identical warning per
/// row, and the five vocabularies would otherwise carry five copies of the same
/// six lines.
///
/// The token is a server enum name (`SUPER_GUT`-shaped) — never a value, never a
/// note, never an identifier, never anything read off the record — so it is
/// operator-grade and logged `.public`, exactly like the two W3 registers it is
/// modelled on. That is the point of the log: an operator reading a sysdiagnose
/// has to be able to see WHICH member to name next, and a redacted token cannot
/// tell them.
enum UnknownServerEnumLog {
    private static let seen = Mutex<Set<String>>([])

    /// - Parameters:
    ///   - raw: the token the server sent.
    ///   - vocabulary: which enum it came from, for the operator's eye.
    ///   - consequence: what the app does with the row now — always a
    ///     degradation, never a drop.
    static func noteFirstSighting(of raw: String, vocabulary: StaticString, consequence: StaticString) {
        let isNew = seen.withLock { $0.insert("\(vocabulary):\(raw)").inserted }
        guard isNew else { return }
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.api.warning(
            "Unknown \(vocabulary, privacy: .public) value \(raw, privacy: .public) — \(consequence, privacy: .public)"
        )
    }
}
