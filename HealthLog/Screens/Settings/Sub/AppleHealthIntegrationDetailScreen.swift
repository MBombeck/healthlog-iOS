import SwiftUI

/// `/settings/integrations/apple-health` — die dedizierte Apple-Health-Detailseite.
///
/// **v0.11 Settings-IA-Restructure:** `SettingsIntegrationsScreen` listet
/// Integrationen jetzt uniform als je eine Nav-Row → eigene Detailseite
/// (wie Withings via `WithingsIntegrationScreen`). Diese Seite hostet alles
/// Apple-Health-Spezifische:
///
/// 1. **Verbindung** — Status-Pill + Connect + Sync-now (aus dem früheren
///    inline `appleHealthCard`-Body von `SettingsIntegrationsScreen`).
/// 2. **Datentypen** — die per-Typ Sync-Toggles, die vorher im Top-Level
///    "Quellen"-Hub (`SettingsSourcesScreen`) gebündelt waren. Reiner Re-Host:
///    `SettingsStore.toggle(syncEntryID:)` + der First-Enable-HK-Auth-
///    Seiteneffekt sind store/readiness-getrieben und damit portabel.
/// 3. **Spezial-Syncs** — Cycle-Opt-in + Mood-Sync (v0.14.8 W2 Settings-IA:
///    von `SettingsHealthAccessScreen` hierher gezogen — sie sind
///    Sync-VERHALTEN wie die Datentyp-Toggles, keine Transparenz-Info).
/// 4. **Transparenz & Diagnose** — Read/Write-Transparenz →
///    `SettingsHealthAccessScreen` (jetzt toggle-frei, reine 5.1.3(i)-Seite)
///    + Sync-Diagnose → `SettingsHKSyncDiagnosticsScreen`.
///
/// Die Cross-Source-Priority-Leiter bleibt bewusst NICHT hier — sie ist ein
/// eigener Top-Level-Settings-Eintrag (`SettingsSourcesScreen`, jetzt
/// priority-only).
struct AppleHealthIntegrationDetailScreen: View {
    @Environment(SettingsStore.self) var store
    @Environment(HKReadinessStore.self) var hkReadiness
    /// Container access for the relocated cycle-opt-in + mood-sync
    /// toggles (cycle gate and store lifecycle, mood sync store).
    /// `internal` (not `private`) so the `+Cycle` extension file can read it.
    @Environment(\.appContainer) var container
    @State private var refreshTick: Int = 0
    /// Whether the HealthKit sheet is answered (`nil`: unknown yet).
    @State private var sheetAnswered: Bool?
    /// Spinner while the State-of-Mind opt-in auth runs.
    @State private var moodSyncInFlight = false
    /// Server-parity v1.16 — cycle purge confirmation + progress/result state.
    /// `internal` so the `+Cycle` extension file can drive them.
    @State var cyclePurgeState: CyclePurgeState = .idle
    /// Whether the neutral cycle-tracking OFFER row is expanded to reveal the
    /// explainer + the actual opt-in action.
    @State var showCycleOfferExplainer = false

    enum CyclePurgeState: Equatable {
        case idle
        case running
        case done
        case failed
    }

    @Environment(\.deviceProfile) private var deviceProfile

    var body: some View {
        if HealthKitAvailabilityPolicy(idiom: deviceProfile.idiom).offersAuthorization {
            phoneBody
        } else {
            AppleHealthPadNotice()
        }
    }

    private var phoneBody: some View {
        HLPage {
            connectionCard
            // How far the older history has got, and
            // "Sync everything now". Server-only: it is the server it fills.
            if Self.showsHistory(status: shownStatus) {
                historyCard
            }
            // A loaded list without a single type rendered a
            // titled card with nothing in it.
            if store.hkConfig?.entries.isEmpty != true {
                dataTypesCard
            }
            specialSyncsCard
            // 1.5 ROUTES — "Send routes" under the centred „Erweitert" link.
            workoutRoutesAdvanced
            // W-B187 (Settings consolidation §A.3) — the one-shot export.zip
            // bulk import folded IN here as a card, so the Integrations list
            // shows ONE "Apple Health" row instead of two confusing peers
            // ("Apple Health" + "Apple Health Import").
            importCard
            transparencyCard
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await hkReadiness.refresh()
            await refreshSheetAnswered()
        }
        .onChange(of: hkReadiness.state) {
            Task { await refreshSheetAnswered() }
        }
        .refreshable {
            await hkReadiness.refresh()
            await refreshSheetAnswered()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    // MARK: - Connection (status + connect + sync-now + transparency rows)

    private var connectionCard: some View {
        HLCard(
            "Apple Health",
            trailing: { appleHealthPill },
            content: { appleHealthBody }
        )
    }

    /// Die Pille meldet die EMPFANGS-Wahrheit, nie den rohen
    /// Schreib-Status. Die Ableitung liegt seit H1 in
    /// `HKReadinessStore.surfaceStatus`, gemalt von ``HealthKitStatusPill``, so
    /// dass die Integrationen-Liste und diese Seite nicht mehr auseinander
    /// laufen können. Die Einschränkung beim Zurückschreiben ist eine eigene
    /// Geschichte und steht als `writeBackNoticeRow` im Kartenkörper.
    private var appleHealthPill: some View {
        HealthKitStatusPill(status: shownStatus, form: .capsule)
    }

    /// The card states one connection. Connected means the permission is
    /// granted; while iOS would still show the permission sheet the card
    /// says "Not connected" over its connect button, not "Connected".
    static func shownStatus(
        _ surface: HKReadinessStore.SurfaceStatus,
        action: HKReadinessStore.ConnectionAction
    ) -> HKReadinessStore.SurfaceStatus {
        if surface == .receiving, action == .connect { return .notConnected }
        return surface
    }

    /// Writing back and syncing only mean something once the connection stands.
    static func isConnected(status: HKReadinessStore.SurfaceStatus) -> Bool {
        status == .receiving
    }

    /// The history card counts types only for a connection that can send any.
    static func showsHistory(status: HKReadinessStore.SurfaceStatus) -> Bool {
        isConnected(status: status)
    }

    private var shownStatus: HKReadinessStore.SurfaceStatus {
        Self.shownStatus(hkReadiness.surfaceStatus, action: connectionAction)
    }

    private var appleHealthBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // Audit-Gruppe 1 — „Lese- und Schreibzugriff auf Vitalwerte“ stand
            // hier ein drittes Mal (Karten-Untertitel auf der Integrationen-
            // Liste, toter Seiten-Untertitel, hier). Heimat ist die Liste, wo
            // die Navigationsentscheidung fällt; der zustandsabhängige
            // Sync-Stand bleibt — er trägt Information, die kein Titel hat.
            Text(syncStateCaption)
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            writeBackNoticeRow
            // One action per state instead of
            // "Connect" and "Open in Apple Health" whenever a write type was
            // missing (the pill said "Connected", the button "Connect"). The
            // review link sits beside the write-back notice it answers.
            if connectionAction == .reviewWriteAccess {
                AppleHealthConnectActions(action: .reviewWriteAccess, connect: {})
            }
            limitedHistoryRow
            serverHealthLine
            if connectionAction != .reviewWriteAccess {
                AppleHealthConnectActions(
                    action: connectionAction,
                    isRequesting: hkReadiness.isRequestingAuthorization,
                    showsNoOpHint: hkReadiness.lastAuthorizationWasNoOp
                ) {
                    Task {
                        await hkReadiness.requestAuthorization()
                        await refreshSheetAnswered()
                    }
                }
            }
            if Self.isConnected(status: shownStatus) {
                HLButton(
                    "Sync now",
                    systemImage: "arrow.triangle.2.circlepath",
                    variant: .secondary,
                    isLoading: hkReadiness.isSyncing
                ) {
                    Task { await hkReadiness.triggerManualSync() }
                }
                .disabled(hkReadiness.isSyncing)
                .accessibilityIdentifier("settings.integrations.appleHealthManualSync")
            }
        }
    }

    /// The card's one action for the current state.
    private var connectionAction: HKReadinessStore.ConnectionAction {
        hkReadiness.connectionAction(sheetAnswered: sheetAnswered)
    }

    private func refreshSheetAnswered() async {
        sheetAnswered = await hkReadiness.authorizationSheetAnswered()
    }

    /// The WRITE-back status, kept strictly separate from
    /// the receive pill. When receiving demonstrably works (`isConnected`) but
    /// not every WRITE type is authorized, we say so honestly ("write-back
    /// limited / off") instead of letting the connection surface claim it
    /// "can't receive". Silent when writes are fully granted or when the user
    /// isn't connected at all (the Connect CTA + pill already own that case).
    @ViewBuilder
    private var writeBackNoticeRow: some View {
        if Self.isConnected(status: shownStatus) {
            switch hkReadiness.state {
            case .denied:
                noticeRow("settings.applehealth.writeback.blocked")
            case .partiallyGranted:
                noticeRow("settings.applehealth.writeback.limited")
            case .unknown, .notRequested, .fullyGranted:
                EmptyView()
            }
        }
    }

    func noticeRow(_ text: LocalizedStringKey, icon: String = "arrow.up.forward.circle") -> some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            Image(systemName: icon)
                .hlText(.footnote)
                .accessibilityHidden(true)
            Text(text)
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The device's own stamp first, the server's `lastSyncedAt` as the
    /// fallback (see `HKReadinessStore.displayedLastSyncedAt`).
    private var syncStateCaption: String {
        if let date = hkReadiness.displayedLastSyncedAt(serverLastSyncedAt: store.hkConfig?.lastSyncedAt) {
            return String(
                localized: "Last synced: \(date.formatted(.relative(presentation: .named)))"
            )
        }
        return String(localized: "Not synced yet")
    }

    // MARK: - Data types

    /// Per-Apple-Health-Type Sync-Toggles. Vorher im Top-Level-"Quellen"-Hub;
    /// gehört IA-logisch unter die Apple-Health-Integration. Server-Logik
    /// unverändert — `SettingsStore.toggle(syncEntryID:)` + der First-Enable-
    /// HK-Auth-Seiteneffekt sind reiner Re-Host.
    private var dataTypesCard: some View {
        HLCard("Apple Health data types") {
            if let config = store.hkConfig {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(config.entries) { entry in
                        dataTypeRow(entry: entry)
                    }
                    // The way back to the new read types.
                    AppleHealthNewReadTypesLink()
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, HLSpace.sm)
            }
        }
    }

    private func dataTypeRow(entry: HealthKitSyncEntry) -> some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HLRowTitle(Text(LocalizedStringKey(entry.kindDisplayName)))
                Text(LocalizedStringKey(directionLabel(entry.direction)))
                    .hlText(.rowSubtitle)
            }
            Spacer(minLength: HLSpace.sm)
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { newValue in
                    Task {
                        await store.toggle(syncEntryID: entry.id)
                        if newValue, !hkReadiness.state.isFullyGranted {
                            await hkReadiness.requestAuthorization()
                        }
                    }
                }
            ))
            .labelsHidden()
            .accessibilityIdentifier("settings.integrations.appleHealth.dataType.\(entry.id)")
        }
    }

    private func directionLabel(_ d: SyncDirection) -> String {
        switch d {
        case .readOnly: String(localized: "Read only")
        case .writeOnly: String(localized: "Write only")
        case .bidirectional: String(localized: "sources.mode.bidirectional")
        case .disabled: String(localized: "Disabled")
        case .unknown: String(localized: "Unknown")
        }
    }

    // MARK: - Special syncs (cycle opt-in + mood — moved here from SettingsHealthAccessScreen)

    /// **v0.14.8 W2 (Settings-IA §3.a)** — the two behaviour toggles that used
    /// to live on the *transparency* page (`SettingsHealthAccessScreen`) are
    /// sync behaviour, exactly like the per-type toggles above, so they belong
    /// on THE Apple-Health surface. Gate logic is unchanged — only the host
    /// moved (flipping the cycle toggle force-enables the `CycleGate` and
    /// starts the C2 HealthKit importer; the toggle is a UI-pref,
    /// `SettingsStore.cycleTrackingOptIn`). Accessibility identifiers are kept
    /// stable (`HealthAccess.*`) so UI tests + deep references keep resolving.
    @ViewBuilder
    private var specialSyncsCard: some View {
        if let container {
            HLCard("settings.applehealth.specialSyncs.title") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    // The gate's availability decides toggle vs a neutral
                    // offer so a non-cycle user never sees a live-looking
                    // "cycle tracking" toggle, while the tertiary-override opt-in
                    // path stays reachable for everyone.
                    switch CycleOptInPresentation.mode(
                        available: container.cycleGate.isCycleTrackingAvailable
                    ) {
                    case .toggle:
                        cycleTrackingToggle(container: container)
                    case .offer:
                        cycleOfferRow(container: container)
                    }
                    moodSyncToggle(store: container.moodHealthSyncStore)
                    // Apple Health medications mirror. Hidden entirely when
                    // HealthKit is unavailable so the row never claims a sync
                    // that can't run.
                    if container.medicationHealthSyncStore.isAvailable {
                        medicationSyncToggle(store: container.medicationHealthSyncStore)
                    }
                    // The Apple-Health ECG upload switch (target
                    // `POST /api/insights/ecg`).
                    ecgSyncToggle(store: container.ecgHealthSyncStore)
                }
            }
        }
    }

    /// The single "Mit Apple Health synchronisieren"
    /// mood toggle. Writes future mood logs into Apple Health's "Mood" track and
    /// imports moods logged elsewhere (anti-duped against our own writes).
    /// 16-03/E2: it now arrives ON for anyone who completed the first HealthKit
    /// sheet; flipping it on by hand is the recovery path and still requests the
    /// State-of-Mind permission at that moment.
    /// The Apple-Health ECG upload switch.
    ///
    /// 16-03/E2: the electrocardiogram READ permission is asked for in the first
    /// sheet now, and a completed grant switches this on wherever there is a
    /// server to upload to. Flipping it on by hand still asks — the recovery
    /// path for a user who declined — and then carries recordings to the server
    /// as they appear.
    ///
    /// **UI-Standard R2, category "Folge".** The one line under the switch says
    /// what turning it on causes and nothing else: the recording, not a reading
    /// of it, leaves the phone. It is not a repetition of the title, not a
    /// default announcement, and not a disclaimer — the ECG attribution copy
    /// lives on the ECG surface where a verdict is actually shown.
    ///
    /// **UI-Standard R11 / E4** — the canonical ``HLSettingsToggleRow``, not a
    /// raw `Toggle`, like the mood and medication switches beside it.
    private func ecgSyncToggle(store: EcgHealthSyncStore) -> some View {
        HLSettingsToggleRow(
            title: "settings.applehealth.ecgSync.label",
            description: "settings.applehealth.ecgSync.footer",
            isOn: Binding(
                get: { store.enabled },
                set: { newValue in
                    Task { await store.setEnabled(newValue) }
                }
            ),
            isBusy: store.isRequestingAuthorization,
            isEnabled: !store.isRequestingAuthorization,
            accessibilityID: "HealthAccess.ecgSyncToggle"
        )
    }

    private func moodSyncToggle(store: MoodHealthSyncStore) -> some View {
        HLSettingsToggleRow(
            title: "settings.applehealth.moodSync.label",
            description: "Write your mood into Apple Health's State of Mind, and import moods you log elsewhere.",
            isOn: Binding(
                get: { store.enabled },
                set: { newValue in
                    Task {
                        moodSyncInFlight = true
                        await store.setEnabled(newValue)
                        moodSyncInFlight = false
                    }
                }
            ),
            isBusy: moodSyncInFlight || store.isRequestingAuthorization,
            isEnabled: !moodSyncInFlight,
            accessibilityID: "HealthAccess.moodSyncToggle"
        )
    }

    /// The "Sync medications with Apple Health" toggle (iOS 26+,
    /// OFF by default). Flipping it on requests opt-in Medications read auth and
    /// mirrors the user's Apple Health medications + their logged doses
    /// (read-only; the app never writes back, and a mirrored med disables its
    /// own manual dose logging to avoid double-counting).
    private func medicationSyncToggle(store: MedicationHealthSyncStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HLSettingsToggleRow(
                title: "settings.applehealth.medSync.label",
                description: "settings.applehealth.medSync.footer",
                isOn: Binding(
                    get: { store.enabled },
                    set: { newValue in
                        Task { await store.setEnabled(newValue) }
                    }
                ),
                isBusy: store.isRequestingAuthorization,
                isEnabled: !store.isRequestingAuthorization,
                accessibilityID: "HealthAccess.medicationSyncToggle"
            )
            // The mirror can be structurally obstructed (cap reached /
            // unstable identifier). Name the reason here instead of letting a
            // generic error banner say "something went wrong" about a condition
            // that has a precise cause.
            if let issue = store.mirrorIssue {
                Text(Self.mirrorIssueCopy(issue))
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("HealthAccess.medicationSyncIssue")
            }
        }
    }

    /// User-facing explanation per ``AppleHealthMirrorIssue``.
    private static func mirrorIssueCopy(_ issue: AppleHealthMirrorIssue) -> LocalizedStringKey {
        switch issue {
        case .limitReached:
            "settings.applehealth.medSync.issue.limitReached"
        case .unstableExternalId:
            "settings.applehealth.medSync.issue.unstableExternalId"
        }
    }

    // W-B187 (Settings consolidation §A.3) — `importCard` (the folded-in one-shot
    // export.zip bulk-import entry point) lives in
    // `AppleHealthIntegrationDetailScreen+Import.swift` to keep this type under
    // the body-length budget. It is rendered above between `specialSyncsCard` and
    // `transparencyCard`.

    // MARK: - Transparency & diagnostics

    /// **v0.14.8 W2 (Settings-IA §3.a)** — the two nav-rows that used to sit
    /// inline in the connection card, grouped into their own card so the page
    /// reads Verbindung → Sync-Verhalten → Transparenz/Diagnose. Accessibility
    /// identifiers unchanged.
    private var transparencyCard: some View {
        HLCard("settings.applehealth.transparency.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Apple Guideline 5.1.3(i) transparency — discoverable in-app
                // surface that lists every HealthKit type HealthLog reads +
                // writes (toggle-free since v0.14.8 W2).
                HLSettingsActionRow(title: "health.permissions.nav_row", presents: .push) {
                    SettingsHealthAccessScreen()
                }
                .accessibilityIdentifier("settings.integrations.healthAccessRow")

                // Per-kind sync diagnostics drilldown.
                HLSettingsActionRow(title: "settings.hkdiag.nav_row", presents: .push) {
                    SettingsHKSyncDiagnosticsScreen()
                }
                .accessibilityIdentifier("settings.integrations.hkDiagnosticsRow")
            }
        }
    }
}
