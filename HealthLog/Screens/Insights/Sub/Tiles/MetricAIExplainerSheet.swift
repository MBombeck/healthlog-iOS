import SwiftUI

/// v0.10.0 W-Insights (R2 Phase B / §3.5 / §6.5) — per-tile, on-tap AI
/// explainer. Presented from a tile's `✦` affordance as a `.medium`-detent
/// sheet (R2 §6.5 decision: a sheet keeps the scroll position stable + avoids
/// reflowing the calm grid). Wraps the EXISTING on-device
/// `TrendObservationsService.observe(...)` — the building block already ships;
/// this re-homes it from an always-on inline row to a contextual, on-tap
/// surface (operator ask #3 — AI out of the flow).
///
/// **Provenance honesty (RA2 §6):** the "On your device" pill renders ONLY on
/// the genuine on-device arm. Server-sourced text carries no badge.
///
/// **Dismissal:** Home-Compliance pattern (handbook §2.6) — drag-indicator
/// only, no X / Fertig / Abbrechen.
///
/// **Cost:** the service caches per metric/day, so presenting on-tap means the
/// model only runs when the operator asks — cheaper than the prior always-on
/// inline rendering.
struct MetricAIExplainerSheet: View {
    let metric: MetricKind
    let locale: Locale
    let service: TrendObservationsService
    /// Fired by "Ask the coach about this" — the parent pulses the AskCoach
    /// surface (router deep-link). nil hides the button.
    let onAskCoach: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// INV-3 (v0157) — the `series` for this metric is read from the store HERE
    /// (filtered by `metric`) instead of being passed in pre-filtered by the
    /// parent. This keeps the `measurementsStore.recent` Observation dependency on
    /// THIS sheet — a new measurement re-renders only the (presented) explainer,
    /// never the `InsightsScreen` scaffold that hosts the `.sheet`.
    @Environment(MeasurementsStore.self) private var measurementsStore
    @State private var resolved: Resolved = .loading

    init(
        metric: MetricKind,
        locale: Locale = .current,
        service: TrendObservationsService,
        onAskCoach: (() -> Void)? = nil
    ) {
        self.metric = metric
        self.locale = locale
        self.service = service
        self.onAskCoach = onAskCoach
    }

    /// The recent measurements for this metric — read + filtered here so the
    /// store dependency lands on this sheet, not the host screen.
    private var series: [Measurement] {
        measurementsStore.recent.filter { $0.kind == metric }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    header
                    content
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                .padding(.bottom, HLSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .hlScreenBackground()
            .navigationTitle(Text(metric.descriptor.title))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(HLColor.surface)
        .task(id: cacheKey) { await resolve() }
    }

    private var header: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "sparkles")
                .foregroundStyle(HLText.secondary)
            HLSectionLabel(verbatim: String(localized: "Assistant insight"))
            Spacer(minLength: 0)
            if case .onDevice = resolved {
                HLBadge(String(localized: "On your device"), tone: .neutral)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch resolved {
        case .loading:
            HStack(spacing: HLSpace.sm) {
                ProgressView()
                Text(String(localized: "Preparing the assistant's explanation"))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, HLSpace.md)
        case let .onDevice(text), let .server(text):
            observationBody(text)
        case .empty:
            emptyBody
        }
    }

    private func observationBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            Text(text)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)

            // UI-Standard R15 (U1) — der pauschale `briefing.disclaimer` ist
            // hier ersatzlos entfallen; `citationRow` darüber sagt bereits,
            // WORAUF der Assistent geschaut hat (Metrik, Zeitfenster, n) —
            // das ist die Zuschreibung, die diese Fläche trägt.
            citationRow
            if let onAskCoach {
                askCoachButton(onAskCoach)
            }
        }
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text(String(localized: "No assistant insight is available for this metric yet."))
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onAskCoach {
                askCoachButton(onAskCoach)
            }
        }
    }

    /// "What the assistant looked at: <Metric> · last 30 days (n=…)" — reuses
    /// the citation rhythm from `InsightsScreen` so the provenance reads the
    /// same everywhere.
    private var citationRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(String(localized: "What the assistant looked at"))
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            HStack(spacing: HLSpace.xs) {
                HLBadge("\(String(localized: metric.descriptor.title)) · \(String(localized: "last 30 days"))", tone: .neutral)
                let count = windowSampleCount
                if count > 0 {
                    Text(String(localized: "n=\(count)"))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// #31a (monochrome) — the coach-prompt label must read in mono ink, not
    /// the user's accent tint. `.secondary` paints its label via `.tint`
    /// (purple by default), which violated the monochrome doctrine on the
    /// assistant-insight surface. `.ghost` keeps the framed, tappable shape
    /// but renders the label in `HLText.primary` — no tint on the prose.
    private func askCoachButton(_ action: @escaping () -> Void) -> some View {
        HLButton(
            String(localized: "Ask the coach about this"),
            variant: .ghost,
            size: .regular
        ) {
            dismiss()
            action()
        }
        .accessibilityIdentifier("insights.aiExplainer.askCoach")
    }

    private var windowSampleCount: Int {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        return series.filter { $0.kind == metric && $0.recordedAt >= cutoff }.count
    }

    /// v0.11 perf: hoist the day-key formatter to a shared instance instead of
    /// allocating a `DateFormatter` on every body read.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private var cacheKey: String {
        let day = Self.dayKeyFormatter.string(from: Date())
        let lang = locale.language.languageCode?.identifier ?? "de"
        return "\(metric.rawValue).\(lang).\(day)"
    }

    private func resolve() async {
        // Re-use the per-metric/day cache the inline card already populates so
        // the on-tap sheet is instant after the first render that day.
        if let cached = TrendObservationCache.shared.read(for: cacheKey) {
            withAnimation(resolveFade) { resolved = .onDevice(cached.observation) }
            return
        }
        let outcome = await service.observe(metric: metric, series: series, locale: locale)
        withAnimation(resolveFade) {
            if let observation = outcome.observation {
                TrendObservationCache.shared.write(observation, for: cacheKey)
                resolved = .onDevice(observation.observation)
            } else {
                resolved = .empty
            }
        }
    }

    private var resolveFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private enum Resolved: Equatable {
        case loading
        case onDevice(String)
        case server(String)
        case empty
    }
}
