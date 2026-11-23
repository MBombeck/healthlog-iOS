import SwiftUI

/// Presentation helpers for the lab reference-range status. Kept in the
/// Labs screen module (not in `HLBadge`) so the shared badge primitive is
/// untouched.
///
/// `rangeStatus` is the singular server verdict and is rendered as-is, as
/// quiet status text without a capsule. `inRange` reads green; a reading
/// outside its range reads orange, because outside the range is where
/// something may need doing; it is never the red of an alarm. `unknown` stays
/// neutral.
extension LabRangeStatus {
    var badgeTone: HLBadge.Tone {
        switch self {
        case .inRange: .success
        case .below, .above: .warning
        case .unknown: .neutral
        }
    }

    /// Optional leading SF Symbol for the badge (decorative, neutral glyphs).
    var badgeIcon: String? {
        switch self {
        case .inRange: "checkmark"
        case .below: "arrow.down"
        case .above: "arrow.up"
        case .unknown: nil
        }
    }

    /// Localized short label for the badge / VoiceOver.
    var localizedLabel: String {
        switch self {
        case .inRange: String(localized: "labs.range.inRange")
        case .below: String(localized: "labs.range.below")
        case .above: String(localized: "labs.range.above")
        case .unknown: String(localized: "labs.range.unknown")
        }
    }

    /// The range as the quiet status text under a row value. A reading
    /// without a range says nothing in a row; its page names the gap.
    var rowStatus: HLRowStatus? {
        guard self != .unknown else { return nil }
        return HLRowStatus(localizedLabel, icon: badgeIcon, tone: badgeTone)
    }
}

/// The range verdict as quiet text, the one form on every lab surface.
struct LabRangeBadge: View {
    let status: LabRangeStatus
    var form: HLBadge.Form = .text

    var body: some View {
        HLBadge(status.localizedLabel, icon: status.badgeIcon, tone: status.badgeTone, form: form)
    }
}
