import SwiftUI

/// v1.25 (GH iOS #38) — the "what changed since your last panel" awareness card.
///
/// Renders `GET /api/insights/labs-changes` (`InsightsLabsChangesDTO`): the
/// per-analyte signed delta between the user's two most-recent numeric lab
/// panels, each tagged with the latest value's reference-band standing.
/// **Server-authoritative, render-don't-recompute** — the delta + status arrive
/// already finished; iOS only paints them.
///
/// **Neutral framing** ("A change is not a diagnosis") mirrors the server's
/// register. The card **self-suppresses** when there are fewer than two panels
/// or no shared analyte. Mounted at the top of `LabsScreen`'s list.
struct LabsChangesCard: View {
    let changes: InsightsLabsChangesDTO?
    /// FW-LABS-BANNER (b210) — tap on the dismiss "x". `nil` hides the affordance
    /// (e.g. previews); the host wires this to persist the dismissal keyed on the
    /// current panel date so the banner re-shows when a newer panel lands.
    var onDismiss: (() -> Void)?

    var body: some View {
        if let changes, changes.hasContent {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                        HLSectionLabel("clinicalSignals.labs.title")
                        if let onDismiss {
                            Spacer(minLength: HLSpace.sm)
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                                    .font(.hlCaption.weight(.semibold))
                                    .foregroundStyle(HLText.tertiary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("clinicalSignals.labs.dismiss"))
                            .accessibilityIdentifier("labs.clinicalSignals.dismiss")
                        }
                    }

                    if let since = sinceLine {
                        Text(since)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }

                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(changes.changes) { change in
                            ChangeRow(change: change)
                            if change.id != changes.changes.last?.id {
                                Divider().background(HLColor.separator)
                            }
                        }
                    }

                    Text("clinicalSignals.labs.caption")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("labs.clinicalSignals.changes")
        }
    }

    private var sinceLine: String? {
        guard let latest = changes?.latestDate, let previous = changes?.previousDate else { return nil }
        return String(format: String(localized: "clinicalSignals.labs.since"), latest, previous)
    }
}

/// One analyte delta row: name + latest value/unit + a signed delta + the
/// NEUTRAL reference-band badge (reuses the Labs badge mapping).
private struct ChangeRow: View {
    let change: InsightsLabsChangesDTO.Change

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(change.analyte)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Text(deltaLine)
                    .font(.hlCaption)
                    .monospacedDigit()
                    .foregroundStyle(HLText.secondary)
            }
            Spacer(minLength: HLSpace.sm)
            VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                Text(valueLabel)
                    .font(.hlSubhead.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(HLText.primary)
                if let status = LabRangeStatus(rawValue: change.status) {
                    LabRangeBadge(status: status)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var valueLabel: String {
        let value = Self.format(change.latest)
        return change.unit.isEmpty ? value : "\(value) \(change.unit)"
    }

    /// Signed delta with an explicit +/− and the direction glyph.
    private var deltaLine: String {
        let glyph = switch change.direction {
        case "up": "↑"
        case "down": "↓"
        default: "→"
        }
        let signed = (change.delta > 0 ? "+" : "") + Self.format(change.delta)
        let previous = Self.format(change.previous)
        return "\(glyph) \(signed)  ·  \(String(localized: "clinicalSignals.labs.previous")) \(previous)"
    }

    private var accessibilityText: String {
        let status = LabRangeStatus(rawValue: change.status)?.localizedLabel ?? ""
        return "\(change.analyte). \(valueLabel). \(deltaLine). \(status)"
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

// MARK: - Dismissal persistence

/// **FW-LABS-BANNER (b210) — device-local dismissal for the labs-changes banner.**
///
/// The operator likes the banner but wants to make it go away — especially when
/// the panel is very old. We persist the `latestDate` (`YYYY-MM-DD`) of the panel
/// the banner was dismissed for. The card stays hidden while the current
/// `latestDate` matches the stored value; a NEWER panel carries a different
/// `latestDate`, so the banner naturally re-shows once fresh labs arrive (the
/// re-show mechanism the brief asks to keep).
///
/// **Storage tier — UserDefaults (device-local UI pref).** No PHI: a single
/// date-string. Mirrors the `ThresholdNudgePrefStore` / `LockScreenPrivacy`
/// precedent for per-device UI state the server does not own.
enum LabsChangesDismissStore {
    /// UserDefaults key for the dismissed panel date.
    static let dismissedPanelKey = "hl.labs.changesBanner.dismissedPanelDate.v1"

    /// The `latestDate` the banner was last dismissed for, or `nil` when never
    /// dismissed.
    static func dismissedPanelDate(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: dismissedPanelKey)
    }

    /// Persist (or clear) the dismissed panel date.
    static func setDismissedPanelDate(_ date: String?, defaults: UserDefaults = .standard) {
        if let date {
            defaults.set(date, forKey: dismissedPanelKey)
        } else {
            defaults.removeObject(forKey: dismissedPanelKey)
        }
    }
}
