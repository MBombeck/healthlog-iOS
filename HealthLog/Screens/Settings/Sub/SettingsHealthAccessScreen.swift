import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(HealthKit)
    import HealthKit
#endif

/// `/settings/integrations/healthkit-access` — **HealthKit-Zugriff** (v0.7.0
/// W-APPSTORE / Apple Guideline 5.1.3(i)).
///
/// One screen that enumerates **every** HealthKit type HealthLog reads from
/// and writes to Apple Health, so the user can audit the full data-access
/// surface in plain language before granting (or after revoking) permission.
/// Apple-App-Review (Guideline 5.1.3(i) — "data minimization / transparency")
/// expects a discoverable in-app surface that explains the health-data access
/// beyond the system permission sheet's terse type list.
///
/// **Single source of truth — no hardcoded duplicate list:** both sections
/// are generated directly from `HealthKitService.defaultReadTypes` and
/// `defaultWriteTypes` (the same sets passed to
/// `requestAuthorization(read:write:)`), plus — once the cycle gate is open —
/// the reproductive set from `CycleHealthKitImporter.readCategoryTypes()`
/// (requested read+share via `requestCycleAuthorization()`; deliberately kept
/// OUT of the default sets so ineligible users are never prompted). If a
/// future release adds a read or write type, it appears here automatically —
/// the only per-type addition is a localized display name in
/// ``HealthAccessTypeNaming`` (HealthKit ships no localized names for
/// `HKObjectType`). The rows are sorted by their resolved display name so the
/// order is stable + readable regardless of `Set` iteration order.
///
/// **16-03 / decision E2 (operator, 2026-08-22).** The ECG and State-of-Mind
/// types are now in the default sets and therefore on both lists
/// unconditionally; the two toggle-gated joins that used to bring them here are
/// gone. The operator attached this to his own answer, in his own words: a
/// larger first permission dialog with an unchanged transparency page is a
/// review risk, not a detail — so the two halves ship in the same change, and
/// `HealthAccessTransparencyTests` proves the lists are DERIVED from the
/// enlarged sets rather than merely still rendering.
///
/// The cycle set stays conditional and is the only thing left that is: it is a
/// separate opt-in with its own legal surface, men are never prompted for it,
/// and E2 said nothing about it. Apple medications are on neither list, and
/// belong on neither: the type is iOS-26-only, needs
/// `requestPerObjectReadAuthorization`, and appears here only through the
/// settings toggle that is its single authorization path.
///
/// **v0.14.8 W2 (Settings-IA §3.a)** — this page is now a PURE transparency
/// surface: the cycle-opt-in + mood-sync behaviour toggles moved onto
/// `AppleHealthIntegrationDetailScreen` (they are sync behaviour, not access
/// transparency — having controls on the "we only show, never switch" page
/// undermined the 5.1.3(i) promise).
///
/// **H1 (Betreiber-Befund 2026-07-31) — angefragt ≠ erlaubt.** Bis hierher
/// listete die Seite, was die App *anfragt*, und trug am Schreib-Abschnitt ein
/// grünes Abzeichen. Der Betreiber las das als „ist erteilt“ und schrieb: „Ich
/// kann nicht sehen was freigegeben ist oder so.“ Seither steht neben jedem
/// **Schreib**-Typ der Zustand, den Apple tatsächlich herausgibt, und der
/// **Lese**-Abschnitt sagt ausdrücklich, dass die App das für Lesetypen nicht
/// wissen kann (`authorizationStatus(for:)` ist für Lesetypen bedeutungslos —
/// allein die Frage würde etwas verraten). Ein begründetes „unbekannt“ ist
/// ehrlicher als ein geratenes Häkchen.
struct SettingsHealthAccessScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(HKReadinessStore.self) private var readiness

    var body: some View {
        HLSettingsPage(title: "health.permissions.title") {
            introCard
            readCard
            writeCard
            footerCard
        }
        // QoL-A2 (Glass H1) — scroll-edge glass now owned centrally by the
        // `HLSettingsPage` inner ScrollView; no outer-layer patch here.
        .navigationTitle("health.permissions.title")
        .navigationBarTitleDisplayMode(.inline)
        // Die Schreib-Status kommen aus dem Store-Snapshot; ohne Refresh zeigte
        // die Seite beim Direkteinstieg lauter „nicht bekannt“.
        .task { await readiness.refresh() }
    }

    // MARK: - Cards

    /// Trägt die Asymmetrie **einmal** (R3): was die Liste ist, und warum für
    /// Lesetypen kein Zustand danebensteht.
    private var introCard: some View {
        HLSettingsCard(
            icon: "heart.text.square.fill",
            title: "health.permissions.intro_title"
        ) {
            Text("health.permissions.intro_body")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readCard: some View {
        HLSettingsCard(
            icon: "arrow.down.heart.fill",
            title: "health.permissions.read_title",
            subtitle: "health.permissions.read_subtitle",
            trailing: { HLBadge(String(localized: "health.permissions.badge_read"), tone: .neutral) },
            content: { typeList(rows: readTypeRows, emptyKey: "health.permissions.read_empty") }
        )
    }

    private var writeCard: some View {
        HLSettingsCard(
            icon: "arrow.up.heart.fill",
            title: "health.permissions.write_title",
            subtitle: "health.permissions.write_subtitle",
            // H1 — das Abzeichen benennt die Richtung, nicht den Zustand. In
            // `.success`-Grün las es sich als „alles erteilt“; der erteilte
            // Zustand steht jetzt pro Zeile.
            trailing: { HLBadge(String(localized: "health.permissions.badge_write"), tone: .neutral) },
            content: { typeList(rows: writeTypeRows, emptyKey: "health.permissions.write_empty") }
        )
    }

    /// R4 — der Satz „ändern kannst du das in Apple Health unter …“ war ein
    /// Wegweiser mit einem Pfad, den Apple zwischenzeitlich umbenannt hat (R7).
    /// An seiner Stelle steht die Zeile, die tatsächlich dorthin führt.
    private var footerCard: some View {
        HLSettingsCard(
            icon: "lock.shield.fill",
            title: "health.permissions.control_title",
            footer: "health.permissions.control_footer"
        ) {
            // Abstände kommen vom Primitive (R12) — kein eigener VStack.
            Text("health.permissions.control_body")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = HKReadinessStore.healthAppDeepLink {
                HLSettingsActionRow(
                    title: "Open in Apple Health",
                    presents: .external
                ) {
                    #if canImport(UIKit)
                        UIApplication.shared.open(url)
                    #endif
                }
                .accessibilityIdentifier("health.permissions.openHealthApp")
            }
        }
    }

    // MARK: - Type list

    @ViewBuilder
    private func typeList(rows: [HealthAccessTypeRow], emptyKey: LocalizedStringKey) -> some View {
        if rows.isEmpty {
            Text(emptyKey)
                .font(.hlSubhead)
                .foregroundStyle(HLText.tertiary)
        } else {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                ForEach(rows) { row in
                    HStack(spacing: HLSpace.md) {
                        Image(systemName: "circle.fill")
                            // 5pt bullet dot — micro list-marker geometry, fixed
                            // by design (a scaling bullet would dwarf the row).
                            // swiftlint:disable:next dynamic_type_bypass
                            .font(.system(size: 5))
                            .foregroundStyle(HLText.tertiary)
                        Text(row.name)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: HLSpace.sm)
                        if row.showsStatus {
                            statusLabel(for: row.status)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Der Zustand als Wort plus Zeichen. Bewusst **ohne Rot**: ein nicht
    /// erteilter Schreibtyp ist kein Fehler, sondern eine Entscheidung des
    /// Nutzers — der Empfang läuft davon unberührt weiter.
    @ViewBuilder
    private func statusLabel(for status: HKReadinessStore.AuthStatus?) -> some View {
        let descriptor = Self.statusDescriptor(for: status)
        HStack(spacing: HLSpace.xs) {
            Image(systemName: descriptor.symbol)
                .font(.hlCaption2.weight(.semibold))
            Text(descriptor.title)
                .font(.hlCaption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(descriptor.isGranted ? HLColor.statusOK : HLText.tertiary)
    }

    /// Wort, Zeichen und Tinte pro Zustand. `internal` + `nonisolated`, damit
    /// der Test den Vertrag festnageln kann, ohne den SwiftUI-Body zu
    /// inspizieren (Muster wie `HLSettingsActionRow.trailingSymbol`).
    nonisolated static func statusDescriptor(
        for status: HKReadinessStore.AuthStatus?
    ) -> HealthAccessStatusDescriptor {
        switch status {
        case .sharingAuthorized:
            HealthAccessStatusDescriptor(
                title: String(localized: "health.permissions.status.allowed"),
                symbol: "checkmark.circle.fill",
                isGranted: true
            )
        case .sharingDenied:
            HealthAccessStatusDescriptor(
                title: String(localized: "health.permissions.status.denied"),
                symbol: "circle.slash",
                isGranted: false
            )
        case .notDetermined:
            HealthAccessStatusDescriptor(
                title: String(localized: "health.permissions.status.undecided"),
                symbol: "circle.dotted",
                isGranted: false
            )
        case nil:
            HealthAccessStatusDescriptor(
                title: String(localized: "health.permissions.status.unknown"),
                symbol: "questionmark.circle",
                isGranted: false
            )
        }
    }

    // MARK: - Generated names (single source of truth = HealthKitService sets)

    /// **v0.14.8 W2 (Settings-IA §3.a, transparency gap)** — the reproductive
    /// set is deliberately excluded from `defaultReadTypes`/`defaultWriteTypes`
    /// (men are never prompted — `HealthKitService+Cycle.swift`), so before W2
    /// the granted cycle types never surfaced here. Once the gate is open the
    /// app requests them read+share (`requestCycleAuthorization()` passes the
    /// same `readCategoryTypes()` set to both), so they join BOTH lists.
    private var cycleTypeIdentifiers: [String] {
        #if canImport(HealthKit)
            guard let container, container.cycleGate.isCycleTrackingAvailable else { return [] }
            return CycleHealthKitImporter.readCategoryTypes().map(\.identifier)
        #else
            return []
        #endif
    }

    // **16-03 / decision E2 — the ECG and State-of-Mind types are no longer
    // joined in here, because they are no longer outside the sets this page is
    // generated from.**
    //
    // Two conditional joins used to live at this spot, one per type, and both
    // existed for exactly one reason: the types were opt-in-only, so the page
    // whose whole job is naming what the app asks for could otherwise hold two
    // permissions and name neither. E2 moved both into the first sheet, which
    // makes the joins worse than redundant — an identifier reaching this page
    // twice would render two rows carrying the same `id`.
    //
    // They were removed rather than left standing with a `false` gate. A
    // disabled join is scaffolding that reads as a live rule, and the next
    // reader would have had to prove it was dead before touching either list.

    /// Every read type, sorted by display name so the rendered order is stable
    /// across `Set` iteration. Generated from
    /// ``HealthKitService/defaultReadTypes`` — the very set handed to
    /// `requestAuthorization(read:write:)` — plus the still-gated cycle set, and
    /// never hand-listed. Ohne Zustand: Apple gibt für Lesetypen keinen heraus
    /// (siehe Intro-Karte).
    private var readTypeRows: [HealthAccessTypeRow] {
        #if canImport(HealthKit)
            Self.rows(
                identifiers: Self.readTypeIdentifiers(cycleIdentifiers: cycleTypeIdentifiers),
                statuses: [:],
                showsStatus: false
            )
        #else
            []
        #endif
    }

    /// Every write type, sorted by display name. Generated from
    /// ``HealthKitService/defaultWriteTypes`` plus the still-gated cycle set
    /// (the cycle opt-in requests share on the same types it reads). Mit
    /// Zustand, soweit die App einen hat: der Zyklus-Typ liegt außerhalb des
    /// Default-Sets und bleibt deshalb ehrlich „nicht bekannt“.
    private var writeTypeRows: [HealthAccessTypeRow] {
        #if canImport(HealthKit)
            Self.rows(
                identifiers: Self.writeTypeIdentifiers(cycleIdentifiers: cycleTypeIdentifiers),
                statuses: readiness.writeAuthorizationStatuses,
                showsStatus: true
            )
        #else
            []
        #endif
    }

    #if canImport(HealthKit)
        /// **The derivation, as a value.** Internal and `nonisolated` so the
        /// 5.1.3(i) contract can be pinned without standing up the container
        /// graph — and so "the page derives from the type sets" is something a
        /// test can assert rather than something a reader has to believe. E2's
        /// Auflage is that this page moves with the sets; a page that merely
        /// *renders* proves nothing about where its rows came from.
        nonisolated static func readTypeIdentifiers(cycleIdentifiers: [String]) -> [String] {
            HealthKitService.defaultReadTypes.map(\.identifier) + cycleIdentifiers
        }

        nonisolated static func writeTypeIdentifiers(cycleIdentifiers: [String]) -> [String] {
            HealthKitService.defaultWriteTypes.map(\.identifier) + cycleIdentifiers
        }
    #endif

    /// Identifier → gerenderte Zeilen. `nonisolated static`, damit der Test die
    /// Zuordnung „fehlender Typ ⇒ sichtbar nicht erlaubt“ prüfen kann, ohne
    /// einen Container aufzubauen.
    nonisolated static func rows(
        identifiers: [String],
        statuses: [String: HKReadinessStore.AuthStatus],
        showsStatus: Bool
    ) -> [HealthAccessTypeRow] {
        identifiers
            .map { identifier in
                HealthAccessTypeRow(
                    id: identifier,
                    name: HealthAccessTypeNaming.displayName(for: identifier),
                    status: statuses[identifier],
                    showsStatus: showsStatus
                )
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Type row

/// Eine Zeile der Transparenzliste: Anzeigename plus — nur für Schreibtypen —
/// der Zustand, den Apple herausgibt.
///
/// Auf Dateiebene statt im View verschachtelt, damit der Typ nicht die
/// MainActor-Isolation der `View`-Konformität erbt und die Zuordnung
/// „Identifier → Zeile“ ohne Aktor-Hop testbar bleibt.
struct HealthAccessTypeRow: Identifiable, Equatable {
    let id: String
    let name: String
    /// `nil` ⇒ die App hat für diesen Typ keinen Zustand (jeder Lesetyp, plus
    /// die Opt-in-Schreibtypen außerhalb des Default-Sets).
    let status: HKReadinessStore.AuthStatus?
    /// Ob die Zeile überhaupt einen Zustand zeigen soll. Lesezeilen zeigen
    /// keinen — die Begründung steht einmal in der Intro-Karte, statt an 50
    /// Zeilen „nicht bekannt“ zu wiederholen.
    let showsStatus: Bool
}

/// Wie ein Berechtigungszustand aussieht: Wort, SF-Symbol, und ob er positiv
/// gefärbt wird. Keine Fehlerfarbe — ein nicht erteilter Schreibtyp ist eine
/// Entscheidung des Nutzers, kein Defekt.
struct HealthAccessStatusDescriptor: Equatable {
    let title: String
    let symbol: String
    let isGranted: Bool
}

// MARK: - Type naming

/// Resolves a raw `HKObjectType.identifier` to a localized, human-readable
/// display name. HealthKit exposes no localized names for `HKObjectType`, so a
/// presentation-layer map is unavoidable — but the *set membership* still
/// comes from `HealthKitService.defaultReadTypes`/`defaultWriteTypes` (single
/// source of truth). Identifiers without an explicit mapping fall back to the
/// trimmed raw identifier so a newly-added type is never silently dropped
/// from the transparency surface.
enum HealthAccessTypeNaming {
    static func displayName(for identifier: String) -> String {
        if let key = localizationKey(for: identifier) {
            return String(localized: key)
        }
        // Fail-soft: strip the `HKQuantityTypeIdentifier` / `HKCategoryType
        // Identifier` prefix so an unmapped type still reads better than the
        // raw symbol. The type still surfaces — Guideline 5.1.3(i) compliance
        // never depends on a name being mapped.
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
    }

    /// Maps the raw HK identifier string to a localization key in
    /// `health.permissions.type.*`. Uses raw identifier strings (not the
    /// typed `HKQuantityTypeIdentifier` symbols) so this stays compilable on
    /// platforms where HealthKit is unavailable and so the iOS-17-only
    /// `TimeInDaylight` raw value resolves without an availability guard.
    ///
    /// A flat `[String: LocalizedStringResource]` lookup instead of a 24-arm
    /// `switch` — pure data, no branching, so it stays well under the
    /// cyclomatic-complexity ceiling as the type roster grows.
    ///
    /// Internal (not `private`) so the naming-completeness unit test
    /// (`SettingsHealthAccessNamingTests`) can assert that every identifier in
    /// the authorization sets resolves to a mapped key — the raw-identifier
    /// fallback in `displayName(for:)` must never be reachable in production.
    static func localizationKey(for identifier: String) -> LocalizedStringResource? {
        keyByIdentifier[identifier]
    }

    /// Single mapping table — raw `HKObjectType.identifier` → localization
    /// key. Membership (which types appear) still comes from
    /// `HealthKitService.defaultReadTypes`/`defaultWriteTypes`; this only
    /// resolves a display string for the ones present.
    private static let keyByIdentifier: [String: LocalizedStringResource] = [
        "HKQuantityTypeIdentifierBodyMass": "health.permissions.type.bodyMass",
        "HKQuantityTypeIdentifierBodyFatPercentage": "health.permissions.type.bodyFat",
        "HKQuantityTypeIdentifierBodyTemperature": "health.permissions.type.bodyTemperature",
        "HKQuantityTypeIdentifierBloodPressureSystolic": "health.permissions.type.bloodPressureSystolic",
        "HKQuantityTypeIdentifierBloodPressureDiastolic": "health.permissions.type.bloodPressureDiastolic",
        "HKQuantityTypeIdentifierBloodGlucose": "health.permissions.type.bloodGlucose",
        "HKQuantityTypeIdentifierOxygenSaturation": "health.permissions.type.oxygenSaturation",
        "HKQuantityTypeIdentifierHeartRate": "health.permissions.type.heartRate",
        "HKQuantityTypeIdentifierRestingHeartRate": "health.permissions.type.restingHeartRate",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "health.permissions.type.hrv",
        "HKQuantityTypeIdentifierVO2Max": "health.permissions.type.vo2Max",
        "HKQuantityTypeIdentifierStepCount": "health.permissions.type.stepCount",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "health.permissions.type.activeEnergy",
        "HKQuantityTypeIdentifierFlightsClimbed": "health.permissions.type.flightsClimbed",
        "HKQuantityTypeIdentifierDistanceWalkingRunning": "health.permissions.type.distanceWalkingRunning",
        "HKQuantityTypeIdentifierWalkingSpeed": "health.permissions.type.walkingSpeed",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage": "health.permissions.type.walkingAsymmetry",
        "HKQuantityTypeIdentifierWalkingStepLength": "health.permissions.type.walkingStepLength",
        "HKQuantityTypeIdentifierBodyMassIndex": "health.permissions.type.bmi",
        "HKCategoryTypeIdentifierSleepAnalysis": "health.permissions.type.sleepAnalysis",
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure": "health.permissions.type.environmentalAudio",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure": "health.permissions.type.headphoneAudio",
        "HKQuantityTypeIdentifierTimeInDaylight": "health.permissions.type.timeInDaylight",
        // v0.14.8 W2 follow-up #1 — these four previously fell back to raw
        // identifiers on the transparency lists ("RespiratoryRate",
        // "AppleWalkingSteadiness", "WalkingDoubleSupportPercentage",
        // "HKWorkoutTypeIdentifier"). The W2 report flagged three; the
        // double-support sibling had the identical gap, just off-screen.
        "HKQuantityTypeIdentifierRespiratoryRate": "health.permissions.type.respiratoryRate",
        "HKQuantityTypeIdentifierAppleWalkingSteadiness": "health.permissions.type.walkingSteadiness",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage": "health.permissions.type.doubleSupport",
        "HKWorkoutTypeIdentifier": "health.permissions.type.workouts",
        // v0.14.8 W-HKREAD — nine quantity readers added to close the server
        // READ-coverage gap (server v1.10.0 APPLE_HEALTH_TYPE_MAP). Each joins
        // the always-on transparency list, so each needs a localized name.
        "HKQuantityTypeIdentifierWalkingHeartRateAverage": "health.permissions.type.walkingHeartRateAverage",
        "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute": "health.permissions.type.heartRateRecovery",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": "health.permissions.type.sleepingWristTemperature",
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances": "health.permissions.type.breathingDisturbances",
        "HKQuantityTypeIdentifierLeanBodyMass": "health.permissions.type.leanBodyMass",
        "HKQuantityTypeIdentifierSixMinuteWalkTestDistance": "health.permissions.type.sixMinuteWalk",
        "HKQuantityTypeIdentifierStairAscentSpeed": "health.permissions.type.stairAscentSpeed",
        "HKQuantityTypeIdentifierStairDescentSpeed": "health.permissions.type.stairDescentSpeed",
        "HKQuantityTypeIdentifierNumberOfTimesFallen": "health.permissions.type.numberOfTimesFallen",
        // v0.14.8 W-HKREAD — seven categorical EVENT classes read by the
        // `HeartHealthEventImporter`. Read-only (never written back), but they
        // join the always-on read transparency list and so need names too.
        "HKCategoryTypeIdentifierIrregularHeartRhythmEvent": "health.permissions.type.irregularHeartRhythm",
        "HKCategoryTypeIdentifierHighHeartRateEvent": "health.permissions.type.highHeartRate",
        "HKCategoryTypeIdentifierLowHeartRateEvent": "health.permissions.type.lowHeartRate",
        "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent": "health.permissions.type.walkingSteadinessEvent",
        "HKCategoryTypeIdentifierSleepApneaEvent": "health.permissions.type.sleepApnea",
        "HKCategoryTypeIdentifierAudioExposureEvent": "health.permissions.type.audioExposureEvent",
        "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent": "health.permissions.type.headphoneAudioEvent",
        // 16-03 / E2 — State of Mind is now a first-sheet type, read AND write:
        // the app mirrors recorded moods back into Apple Health. It was added
        // here in v0.14.8 W2 while it was still a settings-only opt-in; the name
        // is unchanged, only what puts it on the list.
        "HKDataTypeStateOfMind": "health.permissions.type.stateOfMind",
        // 16-03 / E2 — likewise the electrocardiogram type, now in the first
        // sheet. READ only: the app never writes an ECG back into Apple Health,
        // which is also what keeps it structurally incapable of moving
        // `HKReadinessStore`'s write-derived connection state.
        "HKDataTypeIdentifierElectrocardiogram": "health.permissions.type.electrocardiogram",
        // v0.14.8 W2 (Settings-IA §3.a) — the gated reproductive/cycle set
        // (only surfaced when `CycleGate.isCycleTrackingAvailable`). The
        // symptom types reuse the established `cycle.symptom.*` capture labels
        // (same wording the user saw when logging) instead of minting
        // duplicate `health.permissions.type.*` strings.
        "HKCategoryTypeIdentifierMenstrualFlow": "health.permissions.type.menstrualFlow",
        "HKCategoryTypeIdentifierIntermenstrualBleeding": "health.permissions.type.intermenstrualBleeding",
        "HKCategoryTypeIdentifierCervicalMucusQuality": "health.permissions.type.cervicalMucus",
        "HKCategoryTypeIdentifierOvulationTestResult": "health.permissions.type.ovulationTest",
        "HKCategoryTypeIdentifierSexualActivity": "health.permissions.type.sexualActivity",
        "HKCategoryTypeIdentifierPregnancyTestResult": "health.permissions.type.pregnancyTest",
        "HKCategoryTypeIdentifierProgesteroneTestResult": "health.permissions.type.progesteroneTest",
        "HKCategoryTypeIdentifierContraceptive": "health.permissions.type.contraceptive",
        "HKCategoryTypeIdentifierAbdominalCramps": "cycle.symptom.cramps",
        "HKCategoryTypeIdentifierHeadache": "cycle.symptom.headache",
        "HKCategoryTypeIdentifierBloating": "cycle.symptom.bloating",
        "HKCategoryTypeIdentifierAcne": "cycle.symptom.acne",
        "HKCategoryTypeIdentifierBreastPain": "cycle.symptom.breast_tenderness",
        "HKCategoryTypeIdentifierFatigue": "cycle.symptom.fatigue",
        "HKCategoryTypeIdentifierLowerBackPain": "cycle.symptom.back_pain",
        "HKCategoryTypeIdentifierSleepChanges": "cycle.symptom.insomnia",
        "HKCategoryTypeIdentifierMoodChanges": "cycle.symptom.mood_swings",
        "HKCategoryTypeIdentifierAppetiteChanges": "cycle.symptom.food_cravings",
        "HKCategoryTypeIdentifierNausea": "cycle.symptom.nausea"
    ]
}

// Kein `#Preview`: die Seite liest seit H1 den `HKReadinessStore` aus der
// Umgebung, und eine Vorschau ohne diesen Store würde beim Öffnen abstürzen
// statt etwas zu zeigen. Die Zustandsvarianten hängen an
// `SettingsHealthAccessScreen.statusDescriptor(for:)` und werden dort getestet.
