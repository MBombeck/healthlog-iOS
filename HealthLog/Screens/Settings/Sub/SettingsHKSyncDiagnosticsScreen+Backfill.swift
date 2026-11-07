import SwiftUI

// SYNC-TRIG (1.5, #138, server v1.43) — the history catch-up as its own
// line on a server freshness row.
//
// Since the history walk, "Sync everything now", the hourly baseline and the
// older medication doses go out as `syncTrigger: "backfill"`, the server moves
// only `metricFreshness[].lastBackfillAt` for them and leaves the live stamps
// alone. Without this line a type whose history was just caught up read as
// quiet; with it the row says both: when new values last arrived, and when
// the history was last filled in. Absent on older servers, then no line.

extension ServerFreshnessFacts {
    /// "History last filled in 3 hours ago", or `nil` when the server does
    /// not report a catch-up for this type.
    var backfillLabel: String? {
        guard let backfill = row.lastBackfillAt else { return nil }
        return String(localized: "settings.hkdiag.freshness_backfill \(Self.relative(backfill))")
    }
}

/// One `metricFreshness` row of the server card: the type, when its newest
/// reading was taken, and the facts under it (last check with its trigger,
/// last new value, last background arrival, entered here, history catch-up).
/// Its own view since SYNC-TRIG so the row can be rendered on its own; the
/// layout is the one the card drew inline before.
struct ServerFreshnessRow: View {
    let row: MetricFreshness
    let seenText: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            // POLISH-C (F-SYNC-1) — at an accessibility text size the time
            // goes under the type instead of being cut ("vor 12 St…").
            if dynamicTypeSize.isAccessibilitySize {
                typeText
                    .fixedSize(horizontal: false, vertical: true)
                seenLabel
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
                    typeText
                    Spacer(minLength: HLSpace.sm)
                    seenLabel
                        .lineLimit(1)
                }
            }
            // Absent on older servers: a fact the server does not send is no line.
            ForEach(ServerFreshnessFacts(row: row).detailLines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var typeText: some View {
        Text(HKSyncDiagnosticsVocabulary.freshnessType(row.type))
            .font(.hlCaption)
            .foregroundStyle(HLText.primary)
    }

    private var seenLabel: some View {
        Text(seenText)
            .font(.hlCaption.monospacedDigit())
            .foregroundStyle(row.stale ? HLColor.statusWarn : HLText.tertiary)
    }
}
