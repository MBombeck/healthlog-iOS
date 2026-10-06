import SwiftUI

/// **#115 1.6 — the date + period-boundary rows of ``CycleCaptureSheet``.**
///
/// The chosen date is labelled with ITS OWN cycle day and "period ended" is
/// offered only where the server says an end can land (`cycleDay` /
/// `periodEndable` on the v1.39 calendar day, see ``CycleCaptureDayContext``).
/// The sheet used to offer both boundaries for any date. Split out of
/// `CycleCaptureSheet.swift` under the type-length discipline.
struct CycleCapturePeriodSection: View {
    let store: CycleStore
    @Binding var date: Date
    @Binding var periodAction: CyclePeriodAction?
    let isSaving: Bool

    private var context: CycleCaptureDayContext {
        CycleCaptureDayContext(
            date: CycleCaptureSheet.dayKey(date),
            days: store.calendar?.days ?? []
        )
    }

    var body: some View {
        let context = context
        Section {
            DatePicker("cycle.capture.date", selection: $date, displayedComponents: [.date])
            if let cycleDay = context.cycleDay {
                Text(String(format: String(localized: "cycle.home.center.cycleDay"), cycleDay))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            // K1 — segmented while every label fits its segment, a menu
            // otherwise („Keine Änderu…" / „Periode gesta…" on the SE).
            HLAdaptiveSegmentedPicker(
                "cycle.capture.period.header",
                selection: $periodAction,
                labels: ["cycle.capture.period.none", "cycle.capture.period.start"]
                    + (context.offersPeriodEnd ? ["cycle.capture.period.end"] : [])
            ) {
                Text("cycle.capture.period.none").tag(CyclePeriodAction?.none)
                Text("cycle.capture.period.start").tag(CyclePeriodAction?.some(.start))
                if context.offersPeriodEnd {
                    Text("cycle.capture.period.end").tag(CyclePeriodAction?.some(.end))
                }
            }
            .disabled(isSaving)
        } header: {
            Text("cycle.capture.period.header")
        } footer: {
            Text("cycle.capture.period.footer")
        }
        // A grid that arrives (or reloads) after "ended" was picked can take the
        // option away; never keep a choice the picker no longer shows.
        .onChange(of: context.offersPeriodEnd) { _, offers in
            if !offers, periodAction == .end { periodAction = nil }
        }
        // Opened from the capture picker the grid may not be loaded yet, and
        // without it the sheet can make no per-date claim.
        .task {
            if store.calendar == nil { await store.load() }
        }
    }
}
