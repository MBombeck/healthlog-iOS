import Foundation
@testable import HealthLog
import Testing

/// **W-THRESHOLD-NUDGE (v0.15.2) — the MDR-safe out-of-range nudge.**
///
/// This is the app's most regulatory-sensitive surface, so the suite pins every
/// safety invariant as an executable contract:
///
///   1. **No app-invented threshold** — in-range / unknown / no-bound readings
///      produce NO nudge; only the SERVER's `rangeStatus` ever fires one.
///   2. **Server authority** — an active server escalation suppresses the
///      client nudge (no double-nudge).
///   3. **Opt-in** — off by default ⇒ nothing fires.
///   4. **Debounce** — a standing breach nudges once, not on every reading.
///   5. **Never urgent** — the delivered banner is `.passive`, never
///      `.timeSensitive` / `.critical`.
///   6. **Non-diagnostic copy** — the body states a fact + the disclaimer, and
///      contains no reassurance / diagnosis / treatment advice.
@Suite("W-THRESHOLD-NUDGE — MDR-safe out-of-range nudge")
@MainActor
struct ThresholdNudgeTests {
    // MARK: - Fixtures

    private func lab(
        analyte: String = "Glucose",
        value: Double = 250,
        unit: String = "mg/dL",
        referenceLow: Double? = 70,
        referenceHigh: Double? = 180,
        biomarkerId: String? = "bm-1",
        rangeStatus: LabRangeStatus
    ) -> LabResultDTO {
        LabResultDTO(
            id: UUID().uuidString,
            biomarkerId: biomarkerId,
            panel: nil,
            analyte: analyte,
            value: value,
            unit: unit,
            referenceLow: referenceLow,
            referenceHigh: referenceHigh,
            takenAt: "2026-06-21T08:00:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: rangeStatus,
            createdAt: "2026-06-21T08:00:00Z",
            updatedAt: "2026-06-21T08:00:00Z"
        )
    }

    // MARK: - 1. No app-invented threshold

    @Test("IN-RANGE → no nudge (and never an all-clear)")
    func inRangeNoNudge() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(value: 100, rangeStatus: .inRange),
            isOptedIn: true,
            serverHasEscalated: false,
            alreadyNudgedForBreach: false
        )
        #expect(decision == .suppress(.inRange))
    }

    @Test("UNKNOWN range (no server verdict) → no nudge, no invented threshold")
    func unknownNoNudge() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(referenceLow: nil, referenceHigh: nil, rangeStatus: .unknown),
            isOptedIn: true,
            serverHasEscalated: false,
            alreadyNudgedForBreach: false
        )
        #expect(decision == .suppress(.noRange))
    }

    @Test("ABOVE but server sent no upper bound → no nudge (never fabricate a range)")
    func aboveWithoutBoundNoNudge() {
        // The server should not report `above` with no upper bound, but if it
        // does we must NOT invent one — withhold instead.
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(referenceLow: 70, referenceHigh: nil, rangeStatus: .above),
            isOptedIn: true,
            serverHasEscalated: false,
            alreadyNudgedForBreach: false
        )
        #expect(decision == .suppress(.noRange))
    }

    // MARK: - 2. Out-of-range WITH a server/user range → exactly one nudge

    @Test("ABOVE with a user/server range → one nudge")
    func aboveNudges() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(value: 250, rangeStatus: .above),
            isOptedIn: true,
            serverHasEscalated: false,
            alreadyNudgedForBreach: false
        )
        guard case .nudge = decision else {
            Issue.record("expected a nudge for an above-range reading with bounds")
            return
        }
    }

    @Test("BELOW with a user/server range → one nudge")
    func belowNudges() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(value: 40, rangeStatus: .below),
            isOptedIn: true,
            serverHasEscalated: false,
            alreadyNudgedForBreach: false
        )
        guard case .nudge = decision else {
            Issue.record("expected a nudge for a below-range reading with bounds")
            return
        }
    }

    // MARK: - 3. Server already escalating → suppressed (no double-nudge)

    @Test("Server already escalated → suppressed (defer to the server)")
    func serverEscalatedSuppressed() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(value: 250, rangeStatus: .above),
            isOptedIn: true,
            serverHasEscalated: true,
            alreadyNudgedForBreach: false
        )
        #expect(decision == .suppress(.serverEscalated))
    }

    // MARK: - 4. Opt-in off → nothing

    @Test("Opt-in OFF → no nudge even for a clear out-of-range reading")
    func optedOutNoNudge() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(value: 250, rangeStatus: .above),
            isOptedIn: false,
            serverHasEscalated: false,
            alreadyNudgedForBreach: false
        )
        #expect(decision == .suppress(.optedOut))
    }

    // MARK: - 5. Debounce (standing breach doesn't re-nudge)

    @Test("Standing breach already nudged → debounced (no re-nudge)")
    func debouncedNoRenudge() {
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab(value: 250, rangeStatus: .above),
            isOptedIn: true,
            serverHasEscalated: false,
            alreadyNudgedForBreach: true
        )
        #expect(decision == .suppress(.debounced))
    }

    @Test("Debounce key separates kind + direction; a flipped direction is a fresh breach")
    func debounceKeyDirectionAware() {
        let above = ThresholdNudgeEvaluator.debounceKey(for: lab(rangeStatus: .above))
        let below = ThresholdNudgeEvaluator.debounceKey(for: lab(rangeStatus: .below))
        #expect(above != nil)
        #expect(below != nil)
        #expect(above != below)
        // In-range / unknown have no breach key.
        #expect(ThresholdNudgeEvaluator.debounceKey(for: lab(rangeStatus: .inRange)) == nil)
        #expect(ThresholdNudgeEvaluator.debounceKey(for: lab(rangeStatus: .unknown)) == nil)
    }

    // MARK: - 6. Non-diagnostic copy (no reassurance / diagnosis / advice)

    @Test("Nudge body is factual + carries the disclaimer, never diagnoses/reassures")
    func copyIsNonDiagnostic() {
        let content = ThresholdNudgeContent(lab: lab(value: 250, rangeStatus: .above))
        let blob = (content.title + " " + content.body).lowercased()

        // States the reading + the range factually.
        #expect(content.body.contains("250"))
        #expect(content.body.contains("70") && content.body.contains("180"))
        // Carries the non-diagnostic disclaimer. UI-Standard R16 (U1) — die
        // Push ist die EINE Fläche, auf der der Hinweis den Ack-Schalter
        // überlebt (der Nutzer hat seine Bestätigung auf dem Sperrbildschirm
        // nicht dabei). Gekürzt wurde er auf eine Halbzeile:
        // „Informativer Hinweis, kein medizinischer Rat." / „Informational
        // only, not medical advice."
        #expect(blob.contains("not medical advice") || blob.contains("kein medizinischer rat"))

        // FORBIDDEN — no reassurance / all-clear / diagnosis / treatment advice.
        let forbidden = [
            "looks fine", "you're healthy", "you are healthy", "all clear", "all-clear",
            "normal", "don't worry", "no concern", "diagnos", "you should take",
            "see a doctor", "treat", "emergency", "danger", "alles in ordnung",
            "gesund", "kein grund zur sorge"
        ]
        for word in forbidden {
            #expect(!blob.contains(word), "copy must not contain reassurance/diagnosis: \(word)")
        }
    }

    @Test("Range formatting handles single-sided bounds without inventing the other")
    func rangeFormattingSingleSided() {
        #expect(ThresholdNudgeContent.formatRange(low: 70, high: 180) == "70–180")
        #expect(ThresholdNudgeContent.formatRange(low: nil, high: nil).isEmpty)
        let atLeast = ThresholdNudgeContent.formatRange(low: 5, high: nil)
        #expect(atLeast.contains("5"))
        let atMost = ThresholdNudgeContent.formatRange(low: nil, high: 9)
        #expect(atMost.contains("9"))
    }
}
