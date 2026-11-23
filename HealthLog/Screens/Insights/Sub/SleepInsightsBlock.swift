import SwiftUI

/// The sleep page's derived block: the three rhythm cards + the multi-night
/// stage composition chart (parity Build 4 · item 4.7).
///
/// A self-contained container so the sleep-only surface owns its own load
/// without widening ``InsightsMetricScreen``'s state or ``AppContainer``'s
/// graph — the sleep metric page mounts it, every other metric page never
/// constructs it and therefore never fires the reads.
///
/// **Nothing here fails loudly.** Both payloads are additive context around a
/// page that already works: a gated-off sleep module, an older server without
/// `/api/sleep/rhythm`, or an account with no stage-bearing rows all resolve
/// to "these sections are absent", never to an error card. A transport failure
/// with nothing yet painted is the one case worth a caption, because otherwise
/// the sections would silently look like "you have no sleep rhythm".
struct SleepInsightsBlock: View {
    /// The days of the page's selected range; the composition chart follows it.
    var rangeDays: Int = SleepStageCompositionCard.maxNights
    @Environment(\.appContainer) private var appContainer
    @State private var store = SleepInsightsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            if let rhythm = store.rhythm {
                SleepRhythmSection(rhythm: rhythm)
            }
            if let breakdown = store.breakdown {
                SleepStageCompositionCard(breakdown: breakdown, rangeDays: rangeDays)
            }
            if store.loadFailed {
                Text("sleep.rhythm.error")
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await store.load(repo: appContainer?.sleepInsightsRepo) }
    }
}
