import Foundation
@testable import HealthLog
import Testing

/// **Phase 25-02 — four operator decisions (E-2026-08-29), the last code block
/// before candidate 271.**
///
/// Each decision is pinned where it can actually break:
///
/// 1. **Score availability.** The Health Score is computed SERVER-SIDE
///    (`Math.round(mean(eligible pillars))`, composition resolved by the
///    health-score-config route) — iOS never recomputes and never reweights.
///    The client half of the decision is the availability gate and the hiding:
///    a digest without a score renders NO ring (the en-dash provisional face
///    dies), and a digest WITH a score renders it regardless of how narrow the
///    backing subset was. A one-input score IS that input's score — decided,
///    not a bug.
/// 2. **The painted „Eigene Auswahl" caption dies; the spoken provenance
///    survives.** The mark was `accessibilityHidden` and its statement rides
///    the ring's accessibility label — the operator's complaint is visual
///    overload, not the statement.
/// 3. **The avatar opens Konto**, and Edit Profile stays reachable inside
///    Konto exactly as today.
/// 4. **The two settings rows leave „Datenschutz und Sicherheit"** for their
///    honest homes: glucose targets to Über mich (static self-medical facts),
///    injection sites to the Medications tab.
/// 5. **The 25-01 card ends when the system says its sheet was answered**
///    (field report, 2026-08-29, build 270): Apple never re-asks a decided
///    write type and never reports read grants, so `.fullyGranted` is
///    unreachable for many real installs and the card could never observe
///    its own success. The operator's requirement is DETECTION, not
///    acknowledgement — `getRequestStatusForAuthorization` answers for reads
///    too (answered vs open, never the grant), and the card believes it.
///
/// Source contracts read line-comment-stripped source (a `//` line naming a
/// symbol is not the symbol) — the same rule 25-01 paid for.
@Suite("Phase 25-02 — four operator decisions (E-2026-08-29)")
struct OperatorDecisions2502Tests {
    // MARK: - 1. Score availability (zero inputs → no tile)

    /// Zero available inputs means the server sends no score, and the hero
    /// must then render NO ring at all — no empty state, no explainer, no
    /// provisional en-dash face. The gate is `TodayHeroCard.availableScore`,
    /// and the en-dash fallback must be gone from the hero source.
    @Test("zero available inputs remove the score ring entirely")
    func zeroInputsRemoveTheScoreRing() throws {
        let hero = try Self.lineStrippedSource(Self.heroPath)
        #expect(
            !hero.contains("\"\u{2013}\"") && hero.contains("availableScore("),
            "EXPECTED_RED: 25-02 zero available inputs still paint a provisional score ring instead of removing the tile"
        )
    }

    /// A score backed by ONE pillar decodes and keeps its value untouched —
    /// the client imposes no breadth minimum of its own. The subset math is
    /// the server's; what iOS owes is to render whatever arrived.
    @Test("a one-input score is that input's score — the client refuses nothing")
    func aOneInputScoreIsThatInputsScore() throws {
        let payload = #"{"score":58,"band":"yellow","delta":null,"composition":["SLEEP"]}"#
        let score = try JSONDecoder().decode(HealthScore.self, from: Data(payload.utf8))
        #expect(score.score == 58)
        #expect(score.composition?.count == 1)
        #expect(score.displayBand == .yellow)
    }

    /// The today-typical composition renders unchanged — score, band and delta
    /// pass through exactly as the server resolved them.
    @Test("the today-typical composition is unchanged")
    func theTypicalCompositionIsUnchanged() throws {
        let payload = #"""
        {"score":82,"band":"green","delta":1,
         "composition":["BLOOD_PRESSURE","SLEEP","FITNESS","LIPIDS","ACTIVITY"]}
        """#
        let score = try JSONDecoder().decode(HealthScore.self, from: Data(payload.utf8))
        #expect(score.score == 82)
        #expect(score.delta == 1)
        #expect(score.displayBand == .green)
        #expect(score.composition?.count == 5)
    }

    // MARK: - 2. The caption

    /// The painted mark and its one definition site are gone from all three
    /// files that carried it — the hero, the (unmounted) tile twin, and the
    /// presentation enum. The catalogue key follows in the same commit.
    @Test("the painted 'Eigene Auswahl' caption is gone")
    func theCaptionUnderTheScoreIsGone() throws {
        let hero = try Self.lineStrippedSource(Self.heroPath)
        let tile = try Self.lineStrippedSource(Self.tilePath)
        let presentation = try Self.lineStrippedSource(Self.presentationPath)
        #expect(
            !hero.contains("chosenCompositionMark") && !tile.contains("chosenCompositionMark")
                && !presentation.contains("chosenCompositionMark"),
            "EXPECTED_RED: 25-02 the painted 'Eigene Auswahl' caption still stands under the dashboard Health Score"
        )
    }

    /// The accessibility function the caption carried is NOT the painted text
    /// (that was `accessibilityHidden`); it is the sentence appended to the
    /// ring's accessibility label. It stays, on both score surfaces.
    @Test("the spoken provenance survives the caption")
    func theSpokenProvenanceSurvivesTheCaption() throws {
        let hero = try Self.lineStrippedSource(Self.heroPath)
        let tile = try Self.lineStrippedSource(Self.tilePath)
        #expect(hero.contains("chosenCompositionA11y"))
        #expect(tile.contains("chosenCompositionA11y"))
    }

    // MARK: - 3. The avatar

    /// The avatar's ONE sheet now presents Konto — the account area as it
    /// appears in Einstellungen — and no longer the bare profile editor.
    @Test("the dashboard avatar opens Konto")
    func theAvatarOpensKonto() throws {
        let toolbar = try Self.lineStrippedSource(Self.toolbarPath)
        #expect(
            toolbar.contains("SettingsAccountScreen(") && !toolbar.contains("EditProfileSheet("),
            "EXPECTED_RED: 25-02 the dashboard avatar still opens the profile editor instead of Konto"
        )
    }

    /// Edit Profile stays reachable from inside Konto exactly as today — the
    /// retarget adds a hop, it removes no surface.
    @Test("Konto keeps the profile editor reachable")
    func kontoKeepsTheProfileEditorReachable() throws {
        let konto = try Self.lineStrippedSource(Self.kontoPath)
        #expect(konto.contains("EditProfileSheet("))
        #expect(konto.contains("settings.account.profileRow"))
    }

    // MARK: - 4. The two settings rows

    /// Glucose targets (the „Ich habe Diabetes" toggle selecting the server's
    /// ADA bands) live on Über mich — beside anamnesis, allergies and family
    /// history — and nothing diabetes-shaped remains under Datenschutz und
    /// Sicherheit.
    @Test("the glucose targets live on Über mich")
    func glucoseTargetsLiveInAboutMe() throws {
        let aboutMe = try Self.lineStrippedSource(Self.aboutMePath)
        let advanced = try Self.lineStrippedSource(Self.advancedPath)
        #expect(
            aboutMe.contains("settings.diabetes.toggle_label") && !advanced.contains("DiabetesStore"),
            "EXPECTED_RED: 25-02 the glucose targets still sit under Datenschutz und Sicherheit"
        )
    }

    /// The injection-site deny-list lives with the medications it governs —
    /// the Medications tab — and leaves Datenschutz und Sicherheit entirely.
    @Test("the injection sites live with the medications")
    func injectionSitesLiveWithMedications() throws {
        let meds = try Self.lineStrippedSource(Self.medsPath)
        let advanced = try Self.lineStrippedSource(Self.advancedPath)
        #expect(
            meds.contains("SettingsInjectionSitesScreen(") && !advanced.contains("SettingsInjectionSitesScreen"),
            "EXPECTED_RED: 25-02 the injection sites still sit under Datenschutz und Sicherheit"
        )
    }

    // MARK: - 5. The card that would not die (field report, 2026-08-29, build 270)

    /// **The operator's exact walk, on his own device:** the
    /// partially-connected card showed, he tapped Verbinden, Apple's sheet
    /// opened, he granted everything — and the card stayed, surviving a
    /// restart. The mechanism: Apple's sheet only ever asks the
    /// not-yet-determined types and never re-asks a decided one, and read
    /// grants (ECG) are unobservable by design — so `.fullyGranted` is
    /// unreachable for any install with one historically unauthorized write
    /// type, and the shipped predicate can never observe success. What the
    /// system DOES answer — for reads too — is whether the sheet is still to
    /// be answered for a set (`getRequestStatusForAuthorization`): after his
    /// completed flow it says `.unnecessary`, and the card must believe it.
    /// Detection, not memory: no local latch, no ✕ needed after granting.
    @Test("the operator's walk: the system answers 'sheet answered' and the card is gone, staying gone after relaunch")
    func aCompletedConnectFlowEndsTheCard() throws {
        let defaults = try Self.freshDefaults()
        HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: defaults)

        let heartRate = "HKQuantityTypeIdentifierHeartRate"
        let bodyMass = "HKQuantityTypeIdentifierBodyMass"
        let stateOfMind = "HKStateOfMindTypeIdentifier"

        // Control — the partially-connected variant shows, exactly as it did
        // on his dashboard: something authorized, the E2 delta still open,
        // the system still answering `.shouldRequest` for it.
        let before: [String: HKReadinessStore.AuthStatus] = [
            heartRate: .sharingAuthorized, bodyMass: .sharingDenied, stateOfMind: .notDetermined
        ]
        let beforeState = HKReadinessStore.computeState(statuses: before, hasRequestedAuthorization: true)
        #expect(
            HealthKitUpdateNotice.visibleVariant(
                state: beforeState, statuses: before, sheetStatus: .open, defaults: defaults
            ) == .newTypes
        )

        // Verbinden: the sheet asks the one askable type and he grants it.
        // The old denial is never re-asked; the ECG read is unreportable.
        let after: [String: HKReadinessStore.AuthStatus] = [
            heartRate: .sharingAuthorized, bodyMass: .sharingDenied, stateOfMind: .sharingAuthorized
        ]
        let afterState = HKReadinessStore.computeState(statuses: after, hasRequestedAuthorization: true)
        // Pinned: `.fullyGranted` is unreachable on this device — the exact
        // reason the shipped predicate could never clear his card.
        #expect(afterState == .partiallyGranted(missing: [bodyMass]))

        // The system now answers `.unnecessary` for the delta set — grant and
        // deny alike flip it; that is Apple's semantics. Three reads: right
        // after the flow (same session), the relaunch that did NOT clear it
        // on hardware, and a device whose user answered via Settings before
        // ever seeing the card — the card never shows there at all.
        let reads = [
            HealthKitUpdateNotice.visibleVariant(
                state: afterState, statuses: after, sheetStatus: .answered, defaults: defaults
            ),
            HealthKitUpdateNotice.visibleVariant(
                state: afterState, statuses: after, sheetStatus: .answered, defaults: defaults
            ),
            HealthKitUpdateNotice.visibleVariant(
                state: beforeState, statuses: before, sheetStatus: .answered, defaults: defaults
            )
        ]
        #expect(
            reads == [nil, nil, nil],
            "EXPECTED_RED: 25-02 the card survives its own completed connect flow — the operator's build-270 walk"
        )
    }

    /// The second walk: the sheet completes with everything denied. The
    /// system's answer is the same `.unnecessary` — answered is answered,
    /// grant or deny — and the card ends without any ✕. The durable route
    /// stays Einstellungen → Apple Health (D-16-03-A), unchanged.
    @Test("an all-denied outcome still ends the card — answered is answered")
    func anAllDeniedOutcomeStillEndsTheCard() throws {
        let defaults = try Self.freshDefaults()
        HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: defaults)

        let statuses: [String: HKReadinessStore.AuthStatus] = [
            "HKQuantityTypeIdentifierHeartRate": .sharingDenied,
            "HKQuantityTypeIdentifierBodyMass": .sharingDenied
        ]
        let state = HKReadinessStore.computeState(statuses: statuses, hasRequestedAuthorization: true)
        // Control — before the flow, the connect card shows (and for the
        // never-answered connect case the ✕ legitimately stays).
        #expect(
            HealthKitUpdateNotice.visibleVariant(
                state: state, statuses: statuses, sheetStatus: .open, defaults: defaults
            ) == .connect
        )

        #expect(
            HealthKitUpdateNotice.visibleVariant(
                state: state, statuses: statuses, sheetStatus: .answered, defaults: defaults
            ) == nil,
            "EXPECTED_RED: 25-02 answered is answered — an all-denied outcome must end the card without the ✕"
        )
    }

    /// The truth has to be ASKED, not remembered: the card queries the
    /// system's sheet status on appearance and re-queries right after its own
    /// Verbinden flow returns — so it leaves in the same session and a fresh
    /// launch asks the system instead of trusting anything cached. No local
    /// "asked" memory exists anywhere in the notice.
    @Test("the card asks the system, not its memory")
    func theCardAsksTheSystemNotItsMemory() throws {
        let card = try Self.lineStrippedSource(Self.cardPath)
        let notice = try Self.lineStrippedSource(Self.noticePath)
        #expect(
            card.contains("authorizationSheetAnswered") && !notice.contains("askedDefaultsKey"),
            "EXPECTED_RED: 25-02 the card never asks the system whether its sheet was answered"
        )
    }

    /// Control (green on both sides): a platform that cannot answer —
    /// `.unknown`, the non-HealthKit seam — falls back to the shipped state
    /// rule, which is 25-01's exact behaviour. The system status only ever
    /// SUPPRESSES, when it affirmatively answers; it never invents a card.
    @Test("an unanswerable platform falls back to the state rule")
    func unknownSheetStatusFallsBackToTheStateRule() throws {
        let defaults = try Self.freshDefaults()
        HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: defaults)
        let statuses: [String: HKReadinessStore.AuthStatus] = [
            "HKQuantityTypeIdentifierHeartRate": .sharingAuthorized,
            "HKStateOfMindTypeIdentifier": .notDetermined
        ]
        let state = HKReadinessStore.computeState(statuses: statuses, hasRequestedAuthorization: true)
        #expect(
            HealthKitUpdateNotice.visibleVariant(
                state: state, statuses: statuses, sheetStatus: .unknown, defaults: defaults
            ) == .newTypes
        )
    }

    /// Control (green on both sides): a fully granted state still clears the
    /// card by itself — the reportable-write short-circuit stays, so a user
    /// who granted via Settings first is never asked again.
    @Test("a fully granted state still clears the card by itself")
    func fullyGrantedStillClearsTheCard() throws {
        let defaults = try Self.freshDefaults()
        HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: defaults)
        let statuses: [String: HKReadinessStore.AuthStatus] = [
            "HKQuantityTypeIdentifierHeartRate": .sharingAuthorized,
            "HKStateOfMindTypeIdentifier": .sharingAuthorized
        ]
        let state = HKReadinessStore.computeState(statuses: statuses, hasRequestedAuthorization: true)
        #expect(HealthKitUpdateNotice.visibleVariant(state: state, statuses: statuses, defaults: defaults) == nil)
    }

    // MARK: - Pins (post-GREEN seams)

    /// The availability gate is the ONE seam the ring renders through:
    /// `nil` score → hidden (zero available inputs, no face, no explainer);
    /// any present score → passed through untouched, however narrow the
    /// server-side subset behind it. A one-input score is that input's score.
    @Test("availableScore hides on nil and passes any score untouched")
    @MainActor
    func availabilityGateHidesOnNilAndPassesAnyScore() {
        let empty = Self.digest(score: nil)
        #expect(TodayHeroCard.availableScore(empty) == nil)

        let one = DailyDigest.Score(value: 58, band: "yellow", delta: nil, configured: nil)
        #expect(TodayHeroCard.availableScore(Self.digest(score: one)) == one)

        let typical = DailyDigest.Score(value: 82, band: "green", delta: 1, configured: true)
        #expect(TodayHeroCard.availableScore(Self.digest(score: typical)) == typical)
    }

    /// The injection-sites door renders only for a person the deny-list can
    /// do anything for — at least one injection medication, active or
    /// archived; a GLP-1 counts as injectable by class (W47).
    @Test("the injection door needs an injection medication")
    @MainActor
    func theInjectionDoorNeedsAnInjectionMedication() {
        #expect(!MedicationsScreen.showsInjectionSitesDoor(medications: []))
        let oral = Medication(id: "m1", name: "Lisinopril", dose: "5 mg", schedule: MedicationSchedule(times: []), deliveryForm: "ORAL")
        #expect(!MedicationsScreen.showsInjectionSitesDoor(medications: [oral]))
        let pen = Medication(id: "m2", name: "Insulin", dose: "10 IE", schedule: MedicationSchedule(times: []), deliveryForm: "INJECTION")
        #expect(MedicationsScreen.showsInjectionSitesDoor(medications: [oral, pen]))
        let glp1 = Medication(id: "m3", name: "Trulicity", dose: "5 mg", treatmentClass: "GLP1", schedule: MedicationSchedule(times: []))
        #expect(MedicationsScreen.showsInjectionSitesDoor(medications: [glp1]))
    }

    /// The avatar's presentation stays exactly ONE sheet — the retarget
    /// changed the destination, never the presentation grammar (a push would
    /// be a new navigation-destination in the Phase-06 census).
    @Test("the avatar surface stays one sheet")
    func theAvatarSurfaceStaysOneSheet() throws {
        let toolbar = try Self.lineStrippedSource(Self.toolbarPath)
        let sheets = toolbar.components(separatedBy: ".sheet(").count - 1
        #expect(sheets == 1)
        #expect(!toolbar.contains(".navigationDestination("))
    }

    private static func digest(score: DailyDigest.Score?) -> DailyDigest {
        DailyDigest(
            generatedAt: "2026-08-29T08:00:00Z",
            phase: "final",
            sleepPending: false,
            score: score,
            topSignal: nil,
            briefingLead: nil,
            line: "Ein ruhiger Tag.",
            worthALook: []
        )
    }

    // MARK: - Paths + helper

    static let heroPath = "HealthLog/Screens/Dashboard/TodayHeroCard.swift"
    static let tilePath = "HealthLog/Screens/Dashboard/HealthScoreTile.swift"
    static let presentationPath = "HealthLog/Screens/Dashboard/HealthScorePresentation.swift"
    static let toolbarPath = "HealthLog/Screens/Dashboard/DashboardProfileToolbar.swift"
    static let kontoPath = "HealthLog/Screens/Settings/Sub/SettingsAccountScreen.swift"
    static let aboutMePath = "HealthLog/Screens/AboutMe/AboutMeScreen.swift"
    static let advancedPath = "HealthLog/Screens/Settings/Sub/SettingsAdvancedScreen.swift"
    static let medsPath = "HealthLog/Screens/Medications/MedicationsScreen.swift"
    static let cardPath = "HealthLog/Components/HealthKitUpdateNoticeCard.swift"
    static let noticePath = "HealthLog/App/HealthKitUpdateNotice.swift"

    /// A private, wiped defaults suite per test — the per-install register the
    /// card's arming/dismissal/asked keys live in.
    static func freshDefaults() throws -> UserDefaults {
        let name = "op-decisions-2502-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Source with `//`-comment lines removed (leading-trimmed). A doc comment
    /// naming a symbol is not the symbol — the half of the house rule these
    /// contracts need (same shape as 25-01's `lineStrippedSource`).
    static func lineStrippedSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
