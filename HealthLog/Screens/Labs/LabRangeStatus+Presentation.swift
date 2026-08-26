import SwiftUI

/// Presentation helpers for the NEUTRAL lab reference-range status. Kept in the
/// Labs screen module (not in `HLBadge`) so the shared badge primitive is
/// untouched.
///
/// **NEUTRAL CONTRACT (server §1 / CONTRACT FACTS).** `rangeStatus` is the
/// singular server-computed verdict and must render calm + informative — NEVER
/// an alarming red for an out-of-range value. Every case maps to a NON-critical
/// `HLBadge.Tone`: `inRange` → `.success` (the only sanctioned signal colour,
/// matching the existing "In range" badge), and `below`/`above`/`unknown` →
/// `.info`/`.neutral`. There is deliberately NO `.critical`/`.warning` branch.
extension LabRangeStatus {
    /// NEUTRAL badge tone. `inRange` reuses the calm green "In range" signal;
    /// out-of-range stays `.info` (cyan, mono text scale) — informative, never
    /// an alarm. `unknown` is fully neutral.
    var badgeTone: HLBadge.Tone {
        switch self {
        case .inRange: .success
        case .below, .above: .info
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
}

/// The neutral range badge used on list rows + detail. A thin wrapper over
/// ``HLBadge`` that enforces the neutral tone mapping in one place.
struct LabRangeBadge: View {
    let status: LabRangeStatus

    var body: some View {
        HLBadge(status.localizedLabel, icon: status.badgeIcon, tone: status.badgeTone)
    }
}
