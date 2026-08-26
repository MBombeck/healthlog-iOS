import SwiftUI

/// W-B180 — ←/→ night navigation row for ``SleepHypnogramScreen``.
///
/// Operates purely in UTC day-key space (`YYYY-MM-DD`; the wake-day anchors
/// are midnight UTC) so the device timezone can never shift a key by a day.
/// The forward arrow stops at the latest night (no browsing into the
/// future); the back arrow stops at the server's trailing-year read window.
/// Monochrome; both arrows carry localized accessibility labels.
struct SleepNightNavigationHeader: View {
    /// The day-key currently on screen.
    let displayedKey: String
    /// The latest night's resolved day-key — the forward navigation edge.
    /// `nil` (explicit-date entry before the latest resolved) falls back to
    /// the local today.
    let latestDayKey: String?
    /// Disables both arrows while a load is in flight.
    let isLoading: Bool
    /// Called with the target day-key when the user navigates.
    let onNavigate: (String) -> Void

    var body: some View {
        HStack(spacing: HLSpace.md) {
            navArrow(
                "chevron.left",
                labelKey: "sleep.nav.previous",
                enabled: canNavigate(by: -1)
            ) { navigate(by: -1) }
            Spacer()
            // Parity 4.7 — the wake day re-anchored to LOCAL midnight and
            // formatted locally, the same value the summary card below now
            // shows. See ``SleepNightDay`` for why the day-key ARITHMETIC
            // stays in UTC while the DISPLAY is local.
            if let day = SleepNightDay.localAnchor(forDayKey: displayedKey) {
                Text(day, format: SleepNightDay.labelStyle())
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            navArrow(
                "chevron.right",
                labelKey: "sleep.nav.next",
                enabled: canNavigate(by: 1)
            ) { navigate(by: 1) }
        }
    }

    private func navArrow(
        _ systemName: String,
        labelKey: LocalizedStringResource,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.hlHeadline)
                .foregroundStyle(enabled ? HLText.primary : HLText.tertiary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(labelKey))
    }

    private func navigate(by days: Int) {
        guard let target = Self.dayKey(displayedKey, shiftedBy: days) else { return }
        onNavigate(target)
    }

    private func canNavigate(by days: Int) -> Bool {
        guard !isLoading, let target = Self.dayKey(displayedKey, shiftedBy: days) else { return false }
        if days > 0 {
            // Forward edge: never past the latest night (or today, while the
            // latest is still unresolved after an explicit-date entry).
            let upperBound = latestDayKey ?? SleepNightRepository.dayKey(for: .now)
            return target <= upperBound
        }
        // Backward edge: the server reads a trailing-year window.
        let lowerBound = SleepNightRepository.utcDayKey(
            for: Date.now.addingTimeInterval(-365 * 86400)
        )
        return target >= lowerBound
    }

    /// `key` shifted by whole days in UTC day-key space.
    static func dayKey(_ key: String, shiftedBy days: Int) -> String? {
        guard let anchor = SleepNightRepository.date(fromDayKey: key),
              let shifted = utcCalendar.date(byAdding: .day, value: days, to: anchor) else { return nil }
        return SleepNightRepository.utcDayKey(for: shifted)
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()
}
