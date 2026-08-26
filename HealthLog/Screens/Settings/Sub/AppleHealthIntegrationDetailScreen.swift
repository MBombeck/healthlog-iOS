import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

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
    @Environment(SettingsStore.self) private var store
    @Environment(HKReadinessStore.self) private var hkReadiness
    /// v0.14.8 W2 — container access for the relocated cycle-opt-in + mood-sync
    /// toggles (feature flag, cycle store lifecycle, mood sync store).
    /// `internal` (not `private`) so the `+Cycle` extension file can read it.
    @Environment(\.appContainer) var container
    /// Server-parity v1.16 — the cycle purge is a server route; hidden in
    /// standalone (there is nothing server-side to purge). `internal` for `+Cycle`.
    @Environment(BackendAvailability.self) var backend
    @State private var refreshTick: Int = 0
    /// v0.10.0 W-Mood-B — spinner while the State-of-Mind opt-in auth runs.
    @State private var moodSyncInFlight = false
    /// Server-parity v1.16 — cycle purge confirmation + progress/result state.
    /// `internal` so the `+Cycle` extension file can drive them.
    @State var showCyclePurgeConfirmation = false
    @State var cyclePurgeState: CyclePurgeState = .idle
    /// A2 — whether the neutral cycle-tracking OFFER row is expanded to reveal the
    /// explainer + the actual opt-in action.
    @State var showCycleOfferExplainer = false

    enum CyclePurgeState: Equatable {
        case idle
        case running
        case done
        case failed
    }

    var body: some View {
        HLSettingsPage(title: "Apple Health") {
            connectionCard
            dataTypesCard
            specialSyncsCard
            // W-B187 (Settings consolidation §A.3) — the one-shot export.zip
            // bulk import folded IN here as a card, so the Integrations list
            // shows ONE "Apple Health" row instead of two confusing peers
            // ("Apple Health" + "Apple Health Import"). Server-only: gated on
            // `backend.hasServer` (the XML-parse pipeline lives on the server).
            if backend.hasServer {
                importCard
            }
            transparencyCard
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await hkReadiness.refresh() }
        .refreshable {
            await hkReadiness.refresh()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    // MARK: - Connection (status + connect + sync-now + transparency rows)

    private var connectionCard: some View {
        HLSettingsCard(
            icon: "heart.text.square.fill",
            title: "Apple Health",
            trailing: { appleHealthPill },
            content: { appleHealthBody }
        )
    }

    /// P2 (R2-status) — die Pille meldet die EMPFANGS-Wahrheit, nie den rohen
    /// Schreib-Status. Die Ableitung liegt seit H1 in
    /// `HKReadinessStore.surfaceStatus`, gemalt von ``HealthKitStatusPill``, so
    /// dass die Integrationen-Liste und diese Seite nicht mehr auseinander
    /// laufen können. Die Einschränkung beim Zurückschreiben ist eine eigene
    /// Geschichte und steht als `writeBackNoticeRow` im Kartenkörper.
    private var appleHealthPill: some View {
        HealthKitStatusPill()
    }

    private var appleHealthBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // Audit-Gruppe 1 — „Lese- und Schreibzugriff auf Vitalwerte“ stand
            // hier ein drittes Mal (Karten-Untertitel auf der Integrationen-
            // Liste, toter Seiten-Untertitel, hier). Heimat ist die Liste, wo
            // die Navigationsentscheidung fällt (R3); der zustandsabhängige
            // Sync-Stand bleibt — er trägt Information, die kein Titel hat.
            Text(syncStateCaption)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .lineLimit(1)

            writeBackNoticeRow

            if !hkReadiness.state.isFullyGranted {
                HLButton(
                    String(localized: "Connect to Apple Health"),
                    icon: "heart.fill",
                    variant: .primary,
                    isLoading: hkReadiness.isRequestingAuthorization
                ) {
                    Task { await hkReadiness.requestAuthorization() }
                }
                .accessibilityIdentifier("settings.integrations.connectAppleHealth")
            }
            // H1 (Betreiber-Befund 2026-07-31): der Weg nach draußen hing an
            // `lastAuthorizationWasNoOp` — einer In-Memory-Flagge, die jeder
            // App-Start und jeder frische Request löscht. Wer die Seite öffnete,
            // ohne vorher in derselben Sitzung getippt zu haben, sah nie einen
            // Ausweg. Solange nicht alles erteilt ist, ist Apple Health aber die
            // EINZIGE Stelle, an der sich etwas ändern lässt (iOS fragt nie
            // zweimal nach demselben Typ) — also steht der Absprung
            // bedingungslos hier. Die Flagge trägt nur noch den erklärenden
            // Satz, warum der Sheet eben aufblitzte und sich sofort schloss.
            if !hkReadiness.state.isFullyGranted, let url = HKReadinessStore.healthAppDeepLink {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if hkReadiness.lastAuthorizationWasNoOp {
                        Text("settings.integrations.healthapp_hint")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HLButton(
                        String(localized: "Open in Apple Health"),
                        icon: "arrow.up.right.square",
                        variant: .secondary,
                        size: .regular
                    ) {
                        #if canImport(UIKit)
                            UIApplication.shared.open(url)
                        #endif
                    }
                    .accessibilityIdentifier("settings.integrations.openHealthApp")
                }
            }
            HLButton(
                String(localized: "Sync now"),
                icon: "arrow.triangle.2.circlepath",
                variant: .secondary,
                size: .regular,
                isLoading: hkReadiness.isSyncing
            ) {
                Task { await hkReadiness.triggerManualSync() }
            }
            .disabled(hkReadiness.isSyncing)
            .accessibilityIdentifier("settings.integrations.appleHealthManualSync")
        }
    }

    /// **P2 (R2-status)** — the WRITE-back status, kept strictly separate from
    /// the receive pill. When receiving demonstrably works (`isConnected`) but
    /// not every WRITE type is authorized, we say so honestly — "write-back
    /// limited / off" — instead of letting the connection surface claim it
    /// "can't receive". Silent when writes are fully granted (nothing to warn
    /// about) or when the user isn't connected at all (the Connect CTA + pill
    /// already own that case).
    @ViewBuilder
    private var writeBackNoticeRow: some View {
        if hkReadiness.isConnected {
            switch hkReadiness.state {
            case .denied:
                writeBackNotice(text: "settings.applehealth.writeback.blocked")
            case .partiallyGranted:
                writeBackNotice(text: "settings.applehealth.writeback.limited")
            case .unknown, .notRequested, .fullyGranted:
                EmptyView()
            }
        }
    }

    private func writeBackNotice(text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            Image(systemName: "arrow.up.forward.circle")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var syncStateCaption: String {
        if let date = hkReadiness.lastSyncedAt {
            return String(
                localized: "Last synced: \(date.formatted(.relative(presentation: .named)))"
            )
        }
        return String(localized: "Not synced yet")
    }

    // MARK: - Data types (moved from SettingsSourcesScreen v0.11)

    /// Per-Apple-Health-Type Sync-Toggles. Vorher im Top-Level-"Quellen"-Hub;
    /// gehört IA-logisch unter die Apple-Health-Integration. Server-Logik
    /// unverändert — `SettingsStore.toggle(syncEntryID:)` + der First-Enable-
    /// HK-Auth-Seiteneffekt sind reiner Re-Host.
    private var dataTypesCard: some View {
        HLSettingsCard(
            icon: "list.bullet.rectangle.fill",
            title: "Apple Health data types"
        ) {
            if let config = store.hkConfig {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(config.entries) { entry in
                        dataTypeRow(entry: entry)
                    }
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
                Text(LocalizedStringKey(entry.kindDisplayName))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Text(LocalizedStringKey(directionLabel(entry.direction)))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
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
        }
    }

    // MARK: - Special syncs (cycle opt-in + mood — moved here from SettingsHealthAccessScreen)

    /// **v0.14.8 W2 (Settings-IA §3.a)** — the two behaviour toggles that used
    /// to live on the *transparency* page (`SettingsHealthAccessScreen`) are
    /// sync behaviour, exactly like the per-type toggles above, so they belong
    /// on THE Apple-Health surface. Gate logic is unchanged — only the host
    /// moved (the cycle row stays invisible unless `FeatureFlag.cycleTracking`
    /// is on; flipping it force-enables the `CycleGate` and starts the C2
    /// HealthKit importer; the toggle is a UI-pref,
    /// `SettingsStore.cycleTrackingOptIn`). Accessibility identifiers are kept
    /// stable (`HealthAccess.*`) so UI tests + deep references keep resolving.
    @ViewBuilder
    private var specialSyncsCard: some View {
        if let container {
            HLSettingsCard(
                icon: "arrow.triangle.2.circlepath",
                title: "settings.applehealth.specialSyncs.title"
            ) {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    // A2 — three-state cycle opt-in presentation. The flag gates
                    // existence; the gate's availability decides toggle vs a
                    // neutral offer so a non-cycle user never sees a live-looking
                    // "cycle tracking" toggle, while the tertiary-override opt-in
                    // path stays reachable for everyone.
                    switch CycleOptInPresentation.mode(
                        flagOn: container.featureFlagsStore.isEnabled(.cycleTracking),
                        available: container.cycleGate.isCycleTrackingAvailable
                    ) {
                    case .hidden:
                        EmptyView()
                    case .toggle:
                        cycleTrackingToggle(container: container)
                        Divider()
                    case .offer:
                        cycleOfferRow(container: container)
                        Divider()
                    }
                    moodSyncToggle(store: container.moodHealthSyncStore)
                    // GH #47 — Apple Health medications mirror (iOS 26+ only).
                    // Hidden entirely below iOS 26 / when the data type is
                    // unavailable so the row never claims a sync that can't run.
                    if container.medicationHealthSyncStore.isAvailable {
                        Divider()
                        medicationSyncToggle(store: container.medicationHealthSyncStore)
                    }
                    // GH #74 — the Apple-Health ECG upload switch. Server-only:
                    // the target is `POST /api/insights/ecg`, so in standalone
                    // the row would offer a transfer with nowhere to go. Hidden
                    // rather than disabled — an unreachable switch explains
                    // nothing.
                    if backend.hasServer {
                        Divider()
                        ecgSyncToggle(store: container.ecgHealthSyncStore)
                    }
                }
            }
        }
    }

    /// **v0.10.0 W-Mood-B** — the single "Mit Apple Health synchronisieren"
    /// mood toggle. Writes future mood logs into Apple Health's "Mood" track and
    /// imports moods logged elsewhere (anti-duped against our own writes).
    /// 16-03/E2: it now arrives ON for anyone who completed the first HealthKit
    /// sheet; flipping it on by hand is the recovery path and still requests the
    /// State-of-Mind permission at that moment.
    /// **GH #74** — the Apple-Health ECG upload switch.
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
    /// raw `Toggle`. The three neighbouring toggles on this card are still
    /// hand-rolled; they belong to the units that own them, and adding a fourth
    /// hand-rolled row would have grown the ratchet the baseline test guards.
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
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Toggle(
                isOn: Binding(
                    get: { store.enabled },
                    set: { newValue in
                        Task {
                            moodSyncInFlight = true
                            await store.setEnabled(newValue)
                            moodSyncInFlight = false
                        }
                    }
                )
            ) {
                HStack(spacing: HLSpace.sm) {
                    Text("settings.applehealth.moodSync.label")
                        .font(.hlSubhead.weight(.semibold))
                    if moodSyncInFlight || store.isRequestingAuthorization {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .disabled(moodSyncInFlight)
            .accessibilityIdentifier("HealthAccess.moodSyncToggle")
            Text("Write your mood into Apple Health's State of Mind, and import moods you log elsewhere.")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// **GH #47** — the "Sync medications with Apple Health" toggle (iOS 26+,
    /// OFF by default). Flipping it on requests opt-in Medications read auth and
    /// mirrors the user's Apple Health medications + their logged doses
    /// (read-only; the app never writes back, and a mirrored med disables its
    /// own manual dose logging to avoid double-counting).
    private func medicationSyncToggle(store: MedicationHealthSyncStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Toggle(
                isOn: Binding(
                    get: { store.enabled },
                    set: { newValue in
                        Task { await store.setEnabled(newValue) }
                    }
                )
            ) {
                HStack(spacing: HLSpace.sm) {
                    Text("settings.applehealth.medSync.label")
                        .font(.hlSubhead.weight(.semibold))
                    if store.isRequestingAuthorization {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .disabled(store.isRequestingAuthorization)
            .accessibilityIdentifier("HealthAccess.medicationSyncToggle")
            Text("settings.applehealth.medSync.footer")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // CU-10 — the mirror can be structurally obstructed (cap reached /
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
    // `transparencyCard`, server-gated on `backend.hasServer`.

    // MARK: - Transparency & diagnostics

    /// **v0.14.8 W2 (Settings-IA §3.a)** — the two nav-rows that used to sit
    /// inline in the connection card, grouped into their own card so the page
    /// reads Verbindung → Sync-Verhalten → Transparenz/Diagnose. Accessibility
    /// identifiers unchanged.
    private var transparencyCard: some View {
        HLSettingsCard(
            icon: "checklist",
            title: "settings.applehealth.transparency.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Apple Guideline 5.1.3(i) transparency — discoverable in-app
                // surface that lists every HealthKit type HealthLog reads +
                // writes (toggle-free since v0.14.8 W2).
                HLSettingsActionRow(title: "health.permissions.nav_row", presents: .push) {
                    SettingsHealthAccessScreen()
                }
                .accessibilityIdentifier("settings.integrations.healthAccessRow")

                Divider()

                // BF-5: per-kind sync diagnostics drilldown.
                HLSettingsActionRow(title: "settings.hkdiag.nav_row", presents: .push) {
                    SettingsHKSyncDiagnosticsScreen()
                }
                .accessibilityIdentifier("settings.integrations.hkDiagnosticsRow")
            }
        }
    }
}
