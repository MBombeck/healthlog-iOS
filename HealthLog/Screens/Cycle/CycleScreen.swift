import SwiftUI

/// **Phase C5 — the cycle home (women-only, gated).**
///
/// The mirror of the web `/cycle` surface: a hero ``HLCycleRing`` driven by the
/// prediction, a warm phase-aware explainer ("Was passiert gerade mit meinem
/// Körper"), a month calendar of logged + predicted days, and calm prediction +
/// cycle-stats summaries. Reachable only when ``CycleGate/isCycleTrackingAvailable``
/// is true (hard-gated behind `FeatureFlag.cycleTracking`), so an ineligible /
/// opted-out user can never land here.
///
/// **Data path / offline (Z1 / #72).** Reads from ``CycleStore`` (SWR
/// cache-first). The hero ring draws the SERVER's ``CycleVerdictDTO`` — state,
/// phase, arcs, day count, overdue count — and derives none of it. Offline the
/// on-device ``CyclePredictionEngine`` still fills the FORECAST (labelled), and
/// the verdict is the last one the server sent, shown with its "as of" stamp.
/// Past that verdict's own horizon the screen says it has no current assessment
/// rather than aging a judgement forward.
///
/// **Privacy:** cycle data is highly sensitive — this view logs nothing.
struct CycleScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    /// AUD-6 Critical #2 — drives the day-rollover reload. The cycle "today phase"
    /// / day-of-cycle is derived from the loaded calendar; without a foreground
    /// reload it stayed frozen on yesterday's derivation across midnight until a
    /// cold launch (the global foreground path only calls `refreshGateLifecycle()`,
    /// never `load()`). Mirrors the `.onChange(of: scenePhase)` idiom used by
    /// Meds / Dashboard / InsightsMetric.
    @Environment(\.scenePhase) private var scenePhase

    @State private var visibleMonth: Date = .now
    @State private var captureDate: Date?
    @State private var showCapture = false
    @State private var showAdvancedSettings = false

    private var store: CycleStore? {
        container?.cycleStore
    }

    var body: some View {
        Group {
            if let store {
                content(store: store)
            } else {
                CycleUnavailableCard()
            }
        }
        .navigationTitle("cycle.home.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let store, !store.isDisabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdvancedSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("cycle.settings.title"))
                    .accessibilityIdentifier("cycle.home.advancedSettings")
                }
            }
        }
        .task { await store?.load() }
        // AUD-6 Critical #2 — reload the calendar/prediction on foreground so the
        // current-phase / day-of-cycle rolls over at midnight (and an offline
        // fallback prediction upgrades to the server one on reconnect). The
        // `.cycleCalendar(…, day:)` key is day-anchored, so this is a real refetch
        // only when the day actually rolled; otherwise it's served from the 60s
        // within-day cache — cheap.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await store?.load() }
        }
        .sheet(isPresented: $showCapture, onDismiss: reloadAfterCapture, content: captureSheet)
        .sheet(isPresented: $showAdvancedSettings, content: advancedSettingsSheet)
    }

    private func reloadAfterCapture() {
        Task { await store?.load() }
    }

    @ViewBuilder
    private func captureSheet() -> some View {
        if let container {
            CycleCaptureSheet(
                store: container.cycleStore,
                healthKit: container.healthKit,
                initialDate: captureDate,
                onDismiss: { showCapture = false }
            )
            .hlSheetPresentation(.form)
        }
    }

    @ViewBuilder
    private func advancedSettingsSheet() -> some View {
        if let store {
            CycleAdvancedSettingsSheet(store: store, onDismiss: { showAdvancedSettings = false })
                .hlSheetPresentation(.form)
        }
    }

    private func content(store: CycleStore) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HLSpace.xxl) {
                if store.isDisabled {
                    CycleUnavailableCard()
                } else if isColdError(store: store) {
                    // QOL-ERR-1 — a cold offline start (no cached calendar / cycles
                    // and no on-device prediction to fall back to) used to render
                    // the same "still learning" surface as a genuine no-data state.
                    // Surface an honest error + Retry instead. Pull-to-refresh also
                    // re-runs the load.
                    HLRetryUnavailableView { await store.load() }
                } else {
                    heroSection(store: store)
                    if let phase = currentPhase(store: store) {
                        CyclePhaseExplainer(phase: phase, dayOfCycle: store.verdict?.verdict.dayOfCycle)
                    }
                    calendarSection(store: store)
                    CyclePredictionSummary(
                        prediction: store.prediction,
                        today: Self.today,
                        cyclesObserved: cyclesObserved(store: store)
                    )
                    CycleStatsCard(stats: store.stats, cyclesObserved: confirmedCycleCount(store: store))
                    CycleBBTChart(
                        days: store.calendar?.days ?? [],
                        cycles: store.cycles,
                        prediction: store.prediction,
                        rawMode: store.profile?.rawChartMode ?? false,
                        today: Self.today
                    )
                    CycleHistoryChart(
                        cycles: store.cycles,
                        averageLength: store.stats?.avgLengthDays
                    )
                    CycleInsightsSection(store: store)
                    healthSyncFooter
                    // b177 sync-status footer — self-suppresses until the first
                    // sync handshake lands.
                    HLSyncStatusFooter(screenLoading: store.isLoading)
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.md)
            // Normal bottom inset — the previous `.xxxl` cleared the removed
            // bottom log button overlay; without the button the page scrolls
            // fully and only needs a comfortable tail.
            .padding(.bottom, HLSpace.xl)
        }
        .hlScrollEdgeSoft()
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        // QOL-ERR-1 — pull-to-refresh reloads the calendar/prediction.
        .refreshable { await store.load() }
    }

    /// QOL-ERR-1 — true when the last load FAILED and there is genuinely nothing
    /// to render (no cached calendar, no cycle history, and no server / on-device
    /// prediction). Distinguishes a cold error from the legitimate "still
    /// learning" state so the screen can surface a Retry instead of a blank page.
    private func isColdError(store: CycleStore) -> Bool {
        store.lastError != nil
            && store.calendar == nil
            && store.cycles.isEmpty
            && store.prediction == nil
            && store.offlinePrediction == nil
            && store.verdict == nil
    }

    // MARK: - Hero ring

    @ViewBuilder
    private func heroSection(store: CycleStore) -> some View {
        if let model = ringModel(store: store) {
            VStack(spacing: HLSpace.sm) {
                HLCycleRing(
                    model: model,
                    motion: .breathe,
                    glow: .standard,
                    accessibilityLabel: String(localized: "cycle.home.title"),
                    accessibilityValue: "\(model.centerTitle), \(model.centerSubtitle)"
                )
                // The ring reserves an 18% halo margin on every side (see
                // `HLCycleRing.haloInsetFraction`), so the drawn ring is ~64% of
                // this box. 360 keeps the visible ring ~230 pt (unchanged) while
                // giving the additive bloom room to render uncut on all four
                // sides — no `.clipped`.
                .frame(maxWidth: 360)
                .frame(height: 360)
                .frame(maxWidth: .infinity)
                verdictAsOfCaption(store: store)
                provenanceCaption(store: store)
            }
        } else if store.verdict == nil {
            // No verdict at all: offline past the stored one's horizon, or a
            // server older than v1.35.2. The app does NOT reconstruct one — it
            // says it has none. This is deliberately not the "still learning"
            // card, which would claim something about the data.
            CycleVerdictUnavailableCard()
        } else {
            CycleLearningCard()
        }
    }

    /// **Z1 (#72) — the offline "as of" stamp.**
    ///
    /// A verdict is a statement about one specific day, resolved in the user's
    /// PROFILE timezone. Offline the app shows the last one the server sent and
    /// dates it, rather than recomputing a current-looking one on a device that
    /// may sit in a different zone: a day of slip in a forecast is a rounding
    /// error, a day of slip in "overdue" is a false statement about a body.
    /// Self-suppressing — nothing renders while the verdict is live.
    @ViewBuilder
    private func verdictAsOfCaption(store: CycleStore) -> some View {
        if store.verdictIsRestored, let snapshot = store.verdict {
            Text(Self.asOfText(snapshot.asOf))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("cycle.home.verdictAsOf")
        }
    }

    /// **CU-25 (#72) — visible provenance.** The server is the canonical source;
    /// the on-device engine is only the offline / degraded fallback. When the
    /// numbers on the ring came from this device rather than from the record,
    /// the screen says so instead of letting the two silently diverge.
    /// Self-suppressing: nothing renders on the server path.
    @ViewBuilder
    private func provenanceCaption(store: CycleStore) -> some View {
        if store.predictionProvenance == .onDevice {
            Text("cycle.home.prediction.onDevice")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("cycle.home.predictionProvenance")
        }
    }

    // MARK: - Apple-Health sync affordance

    /// **v0.14.8 W2 (Settings-IA §3.b)** — a quiet, caption-grade cross-link to
    /// the Apple-Health sync controls. The only cycle↔HK control used to be
    /// buried three levels deep (Settings → Integrationen → Apple Health) and
    /// was unfindable from here; this footer makes the data flow visible where
    /// the user actually sees the data. Styled after `SyncStatusCaption` (one
    /// centered tertiary caption, no chrome) so it stays the quietest possible
    /// affordance.
    private var healthSyncFooter: some View {
        NavigationLink {
            AppleHealthIntegrationDetailScreen()
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "heart.text.square")
                Text("cycle.health.syncLink")
                HLDisclosureChevron()
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cycle.home.healthSyncLink")
    }

    // MARK: - Calendar

    private func calendarSection(store: CycleStore) -> some View {
        let suppress = suppressFertility(store: store)
        return HLSettingsCard(icon: "calendar", title: "cycle.calendar.title") {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                monthHeader
                CycleCalendarGrid(
                    days: store.calendar?.days ?? [],
                    month: visibleMonth,
                    today: Self.today,
                    suppressFertility: suppress,
                    onSelectDay: { key in
                        captureDate = Self.date(from: key) ?? .now
                        showCapture = true
                    }
                )
                CycleCalendarLegend(suppressFertility: suppress)
            }
        }
    }

    // MARK: - Maturity gate (C1)

    /// The single confirmed-cycle maturity value for the screen. Prefers the
    /// calendar envelope's `profile.cyclesObserved`, then the prediction's
    /// `cyclesObserved`, then the locally counted confirmed cycles already used
    /// for the stats card. Below ``CycleMaturity/minCyclesForFertility`` the
    /// fertile-window / ovulation markers are suppressed (C1 trust + §1.4.1).
    private func cyclesObserved(store: CycleStore) -> Int {
        store.calendar?.profile?.cyclesObserved
            ?? store.prediction?.cyclesObserved
            ?? confirmedCycleCount(store: store)
    }

    private func confirmedCycleCount(store: CycleStore) -> Int {
        store.cycles.filter { !$0.isPredicted }.count
    }

    /// True while the user is still learning — suppresses concrete fertility
    /// markers across the calendar + legend. Also honours the prediction's own
    /// `stillLearning` flag so an older server that only sends the flag still
    /// suppresses.
    private func suppressFertility(store: CycleStore) -> Bool {
        CycleMaturity.suppressFertility(
            cyclesObserved: cyclesObserved(store: store),
            stillLearning: store.prediction?.stillLearning
        )
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left").font(.hlSubhead)
            }
            .accessibilityLabel(Text("cycle.calendar.previousMonth"))
            Spacer()
            Text(Self.monthTitle(visibleMonth))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right").font(.hlSubhead)
            }
            .accessibilityLabel(Text("cycle.calendar.nextMonth"))
        }
        .foregroundStyle(HLText.secondary)
    }

    // MARK: - Model derivation

    private func ringModel(store: CycleStore) -> HLCycleRing.Model? {
        guard let verdict = store.verdict?.verdict else { return nil }
        return CycleScreenModel.ringModel(
            verdict: verdict,
            prediction: store.prediction,
            centerTitle: CycleScreenModel.centerTitle(verdict: verdict, hasPrediction: store.prediction != nil),
            centerSubtitle: CycleScreenModel.centerSubtitle(verdict: verdict),
            // v1.16.15 — keep the hero ring's fertile band / ovulation marker in
            // lockstep with the calendar + summary cards while still learning.
            suppressFertility: suppressFertility(store: store)
        )
    }

    /// Today's phase — the SERVER's, read off the verdict. `nil` in `OVERDUE`
    /// and `INSUFFICIENT_DATA`, and the explainer then simply does not render:
    /// where the record holds no phase, the screen claims none.
    private func currentPhase(store: CycleStore) -> CyclePhasePalette.Phase? {
        CycleScreenModel.phase(store.verdict?.verdict)
    }

    // MARK: - Month paging

    private func shiftMonth(_ delta: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        if let moved = cal.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = moved
        }
    }

    // MARK: - Date helpers (user-tz, POSIX day keys)

    static var today: String {
        CycleCalendarWindow.todayKey()
    }

    static func monthTitle(_ date: Date) -> String {
        monthFormatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        dayFormatter.date(from: key)
    }

    /// "Stand: Gestern, 14:20". Relative where the system offers it, so a
    /// yesterday-old verdict reads as yesterday rather than as a bare date.
    static func asOfText(_ date: Date) -> String {
        String(format: String(localized: "cycle.home.verdict.asOf"), asOfFormatter.string(from: date))
    }

    private static let asOfFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
