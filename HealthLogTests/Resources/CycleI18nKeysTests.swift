import Foundation
@testable import HealthLog
import Testing

/// **v0.14.8 CYCLE-polish — cycle UI string-key catalog audit.**
///
/// The operator's b164 walkthrough surfaced raw humanized key paths on the cycle
/// surface (e.g. "Cycle Home … today", "Cycle … Capture … Start/End"). That is
/// the iOS missing-key fallback: when a `LocalizedStringKey` has no entry in the
/// catalog, the system renders a humanized version of the key path. This suite is
/// the regression anchor: it asserts EVERY cycle UI string key referenced in
/// `CycleScreen`, the calendar grid + legend, `CycleCaptureSheet`, the phase
/// explainer, and the new Insights cycle tile resolves to a non-empty value in
/// BOTH `en` and `de` — so a raw key can never reach the screen unnoticed again.
///
/// Mirrors the proven ``W2I18nKeysTests`` strategy (load the compiled lproj
/// tables from the host-app bundle, assert `resolved != "MISSING"` + non-empty).
/// Excluded by design: `cycle.phase.*.highlight` (asset-catalog image names,
/// passed to `UIImage(named:)`, never localized), `cycle.disabled` /
/// `cycle.tracking` (a server error-code + a feature-flag identifier).
@Suite("CYCLE-polish — cycle UI catalog keys resolve in EN + DE")
struct CycleI18nKeysTests {
    /// Every cycle UI string key referenced in code (grep of `"cycle..."` across
    /// the cycle screens + the Insights tile). Format-args (`%d`) are part of the
    /// stored value; we assert presence + non-empty, not the formatted output.
    static let cycleUIKeys: [String] = [
        // CycleScreen — title, calendar header, hero centre, log action.
        "cycle.home.title",
        "cycle.home.logToday",
        "cycle.home.center.inDays",
        "cycle.home.center.dueToday",
        "cycle.home.center.cycleDay",
        "cycle.home.center.learning.title",
        "cycle.home.center.learning.subtitle",
        // Z1 (#72) — the OVERDUE centre carries `overdueDays`, not a cycle day,
        // and the copy names what the number counts.
        "cycle.home.center.late.title",
        "cycle.home.center.overdue.title",
        "cycle.home.center.overdue.subtitle",
        "cycle.home.center.overdue.subtitle.noStart",
        "cycle.home.center.dueWindow",
        // Provenance + the offline "as of" stamp on a restored verdict.
        "cycle.home.prediction.onDevice",
        "cycle.home.verdict.asOf",
        "cycle.verdict.unavailable.title",
        "cycle.verdict.unavailable.body",
        "cycle.calendar.title",
        "cycle.calendar.previousMonth",
        "cycle.calendar.nextMonth",
        // Calendar a11y.
        "cycle.calendar.a11y.periodLogged",
        "cycle.calendar.a11y.predictedPeriod",
        "cycle.calendar.a11y.ovulation",
        "cycle.calendar.a11y.fertile",
        "cycle.calendar.a11y.symptoms",
        // Legend — one entry per marker family (the no-unexplained-dots invariant).
        "cycle.legend.period",
        "cycle.legend.fertile",
        "cycle.legend.symptoms",
        "cycle.legend.today",
        // Capture sheet — the period start/end actions the operator saw raw.
        "cycle.capture.title",
        "cycle.capture.date",
        "cycle.capture.period.header",
        "cycle.capture.period.start",
        "cycle.capture.period.end",
        "cycle.capture.period.none",
        "cycle.capture.period.footer",
        // CU-25 (#72) — the flow-without-period reconciliation prompt.
        "cycle.capture.reconcile.title",
        "cycle.capture.reconcile.message",
        "cycle.capture.reconcile.confirm",
        "cycle.capture.reconcile.decline",
        "cycle.capture.flow.header",
        "cycle.capture.symptoms.header",
        "cycle.capture.symptoms.severity",
        "cycle.capture.symptoms.severity.none",
        "cycle.capture.fertility.header",
        "cycle.capture.bbt.label",
        "cycle.capture.bbt.value",
        "cycle.capture.ovulation.label",
        "cycle.capture.mucus.label",
        "cycle.capture.option.notSet",
        "cycle.capture.intimacy.header",
        "cycle.capture.intimacy.active",
        "cycle.capture.intimacy.protected",
        "cycle.capture.note.header",
        "cycle.capture.note.placeholder",
        "cycle.capture.error.generic",
        // Phase explainer — title + chip + per-phase name/headline/body.
        "cycle.explain.title",
        "cycle.explain.chip.dayPhase",
        "cycle.phase.menstrual.name",
        "cycle.phase.follicular.name",
        "cycle.phase.ovulatory.name",
        "cycle.phase.luteal.name",
        "cycle.explain.menstrual.headline",
        "cycle.explain.follicular.headline",
        "cycle.explain.ovulatory.headline",
        "cycle.explain.luteal.headline",
        "cycle.explain.menstrual.body",
        "cycle.explain.follicular.body",
        "cycle.explain.ovulatory.body",
        "cycle.explain.luteal.body",
        // Fertility-prediction disclaimer (App Store §1.4.1 / EU MDR fallback).
        "cycle.prediction.disclaimer.local",
        // Summary / learning / unavailable cards.
        "cycle.learning.title",
        "cycle.learning.body",
        "cycle.learning.footer",
        "cycle.unavailable.title",
        "cycle.unavailable.body",
        // NEW (CYCLE-polish) — Insights cycle tile.
        "cycle.insights.tile.heading",
        "cycle.insights.tile.inDays",
        "cycle.insights.tile.dueToday",
        "cycle.insights.tile.learning",
        // v1.16.15 — disturbed-temperature toggle.
        "cycle.capture.bbt.excluded.label",
        "cycle.capture.bbt.excluded.hint",
        // v1.16.15 — cervix secondary-symptom capture (manual-only).
        "cycle.capture.cervix.header",
        "cycle.capture.cervix.footer",
        "cycle.capture.cervix.position.label",
        "cycle.capture.cervix.firmness.label",
        "cycle.capture.cervix.opening.label",
        "cycle.cervix.position.low",
        "cycle.cervix.position.high",
        "cycle.cervix.firmness.firm",
        "cycle.cervix.firmness.soft",
        "cycle.cervix.opening.closed",
        "cycle.cervix.opening.open",
        // v1.16.15 — advanced cycle settings (secondary-symptom pref).
        "cycle.settings.title",
        "cycle.settings.secondarySymptom.header",
        "cycle.settings.secondarySymptom.label",
        "cycle.settings.secondarySymptom.mucus",
        "cycle.settings.secondarySymptom.cervix",
        "cycle.settings.secondarySymptom.footer",
        // Build 5 — capture, settings, analytics, and custom symptoms.
        "cycle.bbt.accessibility.summary",
        "cycle.bbt.axis.celsius",
        "cycle.bbt.axis.date",
        "cycle.bbt.axis.temperature",
        "cycle.bbt.empty",
        "cycle.bbt.ovulation",
        "cycle.bbt.ovulation.confirmed",
        "cycle.bbt.ovulation.estimated",
        "cycle.bbt.series",
        "cycle.bbt.title",
        "cycle.bbt.value",
        "cycle.capture.contraceptive.emergency",
        "cycle.capture.contraceptive.implant",
        "cycle.capture.contraceptive.injection",
        "cycle.capture.contraceptive.iud",
        "cycle.capture.contraceptive.label",
        "cycle.capture.contraceptive.none",
        "cycle.capture.contraceptive.oral",
        "cycle.capture.contraceptive.patch",
        "cycle.capture.contraceptive.ring",
        "cycle.capture.contraceptive.unspecified",
        "cycle.capture.intermenstrualBleeding.label",
        "cycle.capture.pregnancyTest.label",
        "cycle.capture.progesteroneTest.label",
        "cycle.capture.symptoms.category.custom",
        "cycle.capture.symptoms.category.digestive",
        "cycle.capture.symptoms.category.emotional",
        "cycle.capture.symptoms.category.physical",
        "cycle.capture.test.indeterminate",
        "cycle.capture.test.negative",
        "cycle.capture.test.positive",
        "cycle.capture.tests.header",
        "cycle.custom.actions",
        "cycle.custom.create.button",
        "cycle.custom.create.title",
        "cycle.custom.edit.title",
        "cycle.custom.error.generic",
        "cycle.custom.error.invalid",
        "cycle.custom.label.footer",
        "cycle.custom.label.placeholder",
        "cycle.custom.limit",
        "cycle.custom.unnamed",
        "cycle.history.accessibility.summary",
        "cycle.history.average",
        "cycle.history.axis.cycle",
        "cycle.history.axis.days",
        "cycle.history.days.value",
        "cycle.history.empty",
        "cycle.history.ovulation.confirmed",
        "cycle.history.period",
        "cycle.history.series",
        "cycle.history.title",
        "cycle.insights.comparison",
        "cycle.insights.error",
        "cycle.insights.evidence",
        "cycle.insights.headline.title",
        "cycle.insights.learning",
        "cycle.insights.loading",
        "cycle.insights.metric.basalBodyTemp",
        "cycle.insights.metric.bloodGlucose",
        "cycle.insights.metric.heartRateVariability",
        "cycle.insights.metric.mood",
        "cycle.insights.metric.restingHeartRate",
        "cycle.insights.metric.skinTemperature",
        "cycle.insights.metric.sleepDuration",
        "cycle.insights.metric.steps",
        "cycle.insights.metric.weight",
        "cycle.insights.metric.wristTemperature",
        "cycle.insights.phase.unknown",
        "cycle.insights.symptoms.customFallback",
        "cycle.insights.symptoms.distribution",
        "cycle.insights.symptoms.title",
        "cycle.insights.symptoms.topPhase",
        "cycle.insights.symptoms.unknownFallback",
        "cycle.insights.title",
        "cycle.insights.unit.bpm",
        "cycle.insights.unit.celsius",
        "cycle.insights.unit.glucose",
        "cycle.insights.unit.hours",
        "cycle.insights.unit.kg",
        "cycle.insights.unit.ms",
        "cycle.insights.unit.steps",
        "cycle.insights.vitals.title",
        "cycle.settings.discreetNotifications.label",
        "cycle.settings.goal.avoidPregnancy",
        "cycle.settings.goal.generalHealth",
        "cycle.settings.goal.header",
        "cycle.settings.goal.label",
        "cycle.settings.goal.off",
        "cycle.settings.goal.perimenopause",
        "cycle.settings.goal.tryingToConceive",
        "cycle.settings.lutealPhaseLength.label",
        "cycle.settings.prediction.label",
        "cycle.settings.priors.footer",
        "cycle.settings.priors.header",
        "cycle.settings.privacy.header",
        "cycle.settings.range.hint",
        "cycle.settings.rawMode.label",
        "cycle.settings.save.error",
        "cycle.settings.sensitiveEncryption.label",
        "cycle.settings.typicalCycleLength.label",
        "cycle.settings.typicalPeriodLength.label",
        "cycle.settings.validation.error",
        "cycle.symptom.constipation",
        "cycle.symptom.diarrhea",
        "cycle.symptom.libido_high",
        "cycle.symptom.libido_low",
        "cycle.settings.secondarySymptom.error"
    ]

    @Test("Every cycle UI key resolves to a non-empty EN value")
    func englishValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "en")
        for key in Self.cycleUIKeys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing EN entry for cycle key: \(key)")
            #expect(!resolved.isEmpty, "Empty EN value for cycle key: \(key)")
        }
    }

    @Test("Every cycle UI key resolves to a non-empty DE value distinct from the key")
    func germanValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "de")
        for key in Self.cycleUIKeys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing DE entry for cycle key: \(key)")
            #expect(resolved != key, "DE value is the raw key (untranslated): \(key)")
            #expect(!resolved.isEmpty, "Empty DE value for cycle key: \(key)")
        }
    }

    // MARK: - App Store §1.4.1 / EU MDR — fertility prediction always caveated

    /// Builds a `CyclePredictionDTO` from a JSON literal (the type only has a
    /// `Decodable` init), so tests can vary the server `disclaimer` field.
    private static func prediction(disclaimer: String?) throws -> CyclePredictionDTO {
        var dict: [String: Any] = [
            "method": "CALENDAR",
            "nextPeriodStart": "2026-07-01",
            "fertileWindowStart": "2026-06-18",
            "fertileWindowEnd": "2026-06-23",
            "predictedOvulation": "2026-06-21",
            "stillLearning": false
        ]
        if let disclaimer { dict["disclaimer"] = disclaimer }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(CyclePredictionDTO.self, from: data)
    }

    @Test("Server-sent disclaimer is rendered verbatim (server-authoritative)")
    func serverDisclaimerWins() throws {
        let p = try Self.prediction(disclaimer: "  Server caveat text.  ")
        #expect(CyclePredictionSummary.disclaimerSource(p) == .server("Server caveat text."))
    }

    @Test("Blank/absent server disclaimer falls back to the local fertility caveat")
    func localFallbackWhenServerBlank() throws {
        // The whole point of the b182 compliance fix: a fertility/ovulation
        // prediction can NEVER render with zero caveat. Empty string, whitespace,
        // and an entirely absent field must all yield the local fallback caption.
        for blank in [nil, "", "   ", "\n"] {
            let p = try Self.prediction(disclaimer: blank)
            #expect(CyclePredictionSummary.disclaimerSource(p) == .localFallback)
        }
        // And the fallback key must resolve to real copy in both languages.
        for language in ["en", "de"] {
            let bundle = try Self.lprojBundle(language: language)
            let resolved = bundle.localizedString(
                forKey: "cycle.prediction.disclaimer.local", value: "MISSING", table: nil
            )
            #expect(resolved != "MISSING")
            #expect(!resolved.isEmpty)
        }
    }

    // MARK: - Helpers

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw CycleI18nTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum CycleI18nTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
