import Foundation
@testable import HealthLog
import Testing

/// Locks the catalog keys added by the v0.12 WAVE 2 i18n core-extraction
/// (`phase-W2-i18n`) against accidental removal in future xcstrings reflows,
/// and asserts every new key resolves to a non-empty value in BOTH `en` and
/// `de`. Mirrors the strategy of ``V052I18nKeysTests`` — load the compiled
/// `de.lproj` / `en.lproj` tables from the host-app bundle and assert each key
/// resolves to something other than the key itself (which would mean the entry
/// is missing or the catalog wasn't compiled).
///
/// Background: WAVE 2 swapped ~134 hardcoded user-facing literals (many
/// German-only, leaking German into the English locale) for catalog keys with
/// an EN source + DE translation. This suite is the regression anchor for that
/// extraction.
@Suite("v0.12 WAVE 2 i18n keys — catalog presence + DE/EN parity")
struct W2I18nKeysTests {
    /// Representative keys spanning every W2 finding group. Not exhaustive of
    /// all 118 additions, but covers each namespace so a reflow that drops a
    /// group is caught.
    ///
    /// D-12-05-A — "Regulatory disclaimer" left both lists with the MDR
    /// acknowledgment dialog that was its only caller. It is a deletion the
    /// server made first (`0160052289e4` dropped the same section header from
    /// six `messages/*.json`), not a reflow dropping a group, which is exactly
    /// the distinction this suite exists to force someone to make out loud.
    static let w2Keys: [String] = [
        // W2-1 injection sites
        "med.injection.site.abdomen_left_upper",
        "med.injection.site.arm_right",
        // W2-2 sleep stages
        "sleep.stage.deep",
        "sleep.stage.core",
        "sleep.stage.awake",
        // W2-3 trend a11y
        "Trend rising",
        "Trend falling",
        "Trend stable",
        // W2-4 nav titles
        "settings.localreport.title",
        "achievements.title",
        "settings.aiprovider.title",
        // W2-5 form placeholders
        "med.form.name.placeholder",
        "med.form.dose.placeholder",
        "med.form.advanced.section",
        "measurement.form.value.placeholder",
        "measurement.form.recordedAt.section",
        // W2-6 charts
        "chart.axis.y.label",
        "chart.axis.scale.linear",
        "chart.axis.scale.logarithmic",
        "chart.stat.mean",
        "chart.stat.median",
        "chart.aggregation.label",
        "chart.source.manual",
        // W2-7 surface names + isolated
        "cloud_derived.surface.ai_provider",
        "cloud_derived.surface.withings",
        "cloud_derived.surface.source_priority",
        "cloud_derived.surface.server_coach",
        "cloud_derived.surface.insights",
        "coach.onboarding.title",
        "coach.typing.label",
        "aiprovider.badge.saved",
        "aiprovider.badge.configured",
        "dashboard.customize.visible.value",
        "healthscore.pillar.weightTrend",
        "healthscore.source.mixed",
        "trends.averaging.raw",
        "trends.averaging.daily.a11y",
        "sources.mode.bidirectional",
        "export.create.button",
        "glp1.titration.date.label",
        "mood.score.ok",
        "notifications.diagnostics.title",
        "notifications.diagnostics.allowed",
        "notifications.diagnostics.denied",
        "notifications.error.apns.unknown",
        // W2-8 statistik briefing
        "briefing.measurements.none",
        "briefing.mood.today",
        "briefing.mood.latest",
        "briefing.healthscore.weekly",
        // W2-9 insights digest + aux
        "insights.digest.bp.optimal",
        "insights.digest.bp.normal",
        "insights.digest.alert.success",
        "insights.digest.alert.warning",
        "insights.mood.avg7",
        "insights.aux.scheduled",
        "insights.aux.missed",
        // W2-10 chart axis / VoiceOver
        "chart.axis.date",
        "chart.axis.span",
        "chart.axis.zscore",
        "chart.axis.index",
        "chart.series.sparkline",
        "chart.scrubber.selection",
        // v0.13 WR — AI-source matrix card names + subtitles (the headline
        // v0.13 features); these were English-only-in-DE before WR. Plus the
        // BYO consent revoke bullet, the on-device Coach toggle title, the BYO
        // configured-state line, and the two German-literal conversions.
        "Own key",
        "External AI",
        "Use your own AI provider key. Requests go straight from this device to your provider.",
        "Richer findings and Coach from your server's AI provider. Needs a server connection.",
        "You can remove your key at any time in Settings → Assistant.",
        "Coach",
        "Key ····%1$@ · %2$@",
        // #13 (2026-06-11): the heatmap window is operator-selectable; the empty-state
        // key became a %lld format key driven by the picked week count.
        "Once you log medications and acknowledge reminders, your %lld-week compliance history appears here.",
        "Ask me a question about your data — I know your history and can explain what the numbers mean.",
        // v0.13.1 WAVE I18N — German-completeness sweep. The six UnitPreferences
        // picker labels (shipped English-in-DE — the operator's "Settings shows
        // English" report), the three mis-translated cognate keys, the Mood
        // period-control + Insights-aux a11y labels, and the reverse-hygiene
        // German-hardcoded literals re-keyed to an EN source.
        "Kilograms (kg)",
        "Pounds (lb)",
        "Millimeters of mercury (mmHg)",
        "Kilopascals (kPa)",
        "Milligrams per deciliter (mg/dL)",
        "Millimoles per liter (mmol/L)",
        "Self-hosted",
        "Channels",
        "External ID",
        "30 days",
        "90 days",
        "1 year",
        "7-day spread of your mood, from 0 (stable) to 4 (full range).",
        "Order your sources per data type. The topmost source wins when several values exist for the same time.",
        "Sources without values are still shown so you can set the order before a sensor first syncs.",
        "Every metric returns to its original order: Apple Health → Withings → Manual.",
        // swiftlint:disable:next line_length
        "Four pillars: blood pressure on target, weight trend, mood stability, medication compliance. Missing pillars are redistributed proportionally across the ones present — the score never lies about what was actually measured."
    ]

    /// v0.13 WR — universal/near-universal tokens whose DE value intentionally
    /// equals the source key (e.g. "Coach"). Exempted from the `value != key`
    /// "untranslated" assertion in ``germanValuesPresent`` — they are present +
    /// non-empty, just identical across locales.
    static let universalKeys: Set<String> = ["Coach"]

    @Test("Every W2 key resolves to a non-empty German value distinct from the key")
    func germanValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "de")
        for key in Self.w2Keys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing DE entry for key: \(key)")
            if !Self.universalKeys.contains(key) {
                #expect(resolved != key, "DE entry falls back to the key (untranslated): \(key)")
            }
            #expect(!resolved.isEmpty, "Empty DE translation for key: \(key)")
        }
    }

    @Test("Every W2 key resolves to a non-empty English value")
    func englishValuesPresent() throws {
        // Natural-language keys (e.g. "Trend rising") store the English source
        // identical to the key itself, so `resolved == key` is valid there. We
        // assert presence (non-MISSING) + non-empty; the German-leak diff check
        // below proves the dotted keys carry a real EN source.
        let bundle = try Self.lprojBundle(language: "en")
        for key in Self.w2Keys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing EN entry for key: \(key)")
            #expect(!resolved.isEmpty, "Empty EN translation for key: \(key)")
        }
    }

    @Test("German-leak keys actually differ between EN and DE")
    func enDiffersFromDeWhereTranslatable() throws {
        // These were German-only literals leaking into EN; the extraction MUST
        // give them a real English source distinct from the German value.
        let translatable: Set = [
            "med.injection.site.abdomen_left_upper",
            "med.injection.site.arm_right",
            "sleep.stage.deep",
            "sleep.stage.core",
            "sleep.stage.awake",
            "Trend rising",
            "settings.localreport.title",
            "med.form.advanced.section",
            "chart.axis.y.label",
            "chart.source.manual",
            "healthscore.source.mixed",
            "trends.averaging.raw",
            "sources.mode.bidirectional",
            "export.create.button",
            "notifications.diagnostics.allowed",
            "notifications.diagnostics.denied",
            // v0.13 WR — these MUST carry a real DE distinct from the EN source
            // (the regression we are pinning: they shipped English-in-DE).
            "Own key",
            "External AI",
            "Use your own AI provider key. Requests go straight from this device to your provider.",
            "Richer findings and Coach from your server's AI provider. Needs a server connection.",
            "You can remove your key at any time in Settings → Assistant.",
            "Once you log medications and acknowledge reminders, your %lld-week compliance history appears here.",
            "Ask me a question about your data — I know your history and can explain what the numbers mean.",
            // v0.13.1 WAVE I18N — each MUST carry a real DE distinct from the EN
            // source (the regressions we are pinning).
            "Kilograms (kg)",
            "Pounds (lb)",
            "Millimeters of mercury (mmHg)",
            "Kilopascals (kPa)",
            "Milligrams per deciliter (mg/dL)",
            "Millimoles per liter (mmol/L)",
            "Self-hosted",
            "Channels",
            "External ID",
            "30 days",
            "90 days",
            "1 year",
            "7-day spread of your mood, from 0 (stable) to 4 (full range).",
            "Order your sources per data type. The topmost source wins when several values exist for the same time.",
            "Sources without values are still shown so you can set the order before a sensor first syncs.",
            "Every metric returns to its original order: Apple Health → Withings → Manual.",
            // swiftlint:disable:next line_length
            "Four pillars: blood pressure on target, weight trend, mood stability, medication compliance. Missing pillars are redistributed proportionally across the ones present — the score never lies about what was actually measured."
        ]
        let deBundle = try Self.lprojBundle(language: "de")
        let enBundle = try Self.lprojBundle(language: "en")
        for key in translatable {
            let de = deBundle.localizedString(forKey: key, value: "", table: nil)
            let en = enBundle.localizedString(forKey: key, value: "", table: nil)
            #expect(de != en, "EN value equals DE for a translatable key — German leak not fixed: \(key)")
        }
    }

    // MARK: - Helpers

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw I18nTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum I18nTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
