import Foundation
@testable import HealthLog
import Testing

/// v0.7.2 source-language flip (de → en) — runtime no-raw-key acceptance gate.
///
/// After the catalogue flipped to `sourceLanguage: en` and the code literals
/// were realigned to the English keys, the failure mode to guard against is a
/// **raw-key fallback**: a `String(localized:)` / `Text(...)` literal whose
/// derived key no longer matches any catalogue key, so the framework renders
/// the bare key instead of a translation. Under `en` that still happens to read
/// as English (the key *is* the source), masking the break; under `de` it
/// surfaces as English leaking into a German build.
///
/// Strategy: resolve a representative spread of the flipped keys against the
/// **compiled** `de.lproj` and `en.lproj` bundles (the same tables the running
/// app consults — `localizedString(forKey:value:table:)` exercises the real
/// runtime path, including format-specifier round-tripping). For each key
/// assert:
///   1. `en` resolves to the English source (== the key) and is non-empty.
///   2. `de` resolves to the original German (non-empty, differs from the key).
///   3. format-specifier keys carry the same specifier count in both locales,
///      so `String(format:)` substitution stays sound after the flip.
///
/// The sample deliberately mixes plain keys, collision-merged keys, keys with
/// `%@` / `%lld` specifiers, and natural-language sentences — the four shapes
/// that drove the flip's risk register.
@Suite("v0.7.2 source-flip — no raw-key fallback in either locale")
struct SourceFlipNoRawKeyTests {
    /// (English source key, expected German rendering). The German side is the
    /// pre-flip source string, now living in the `de` localization unit. Picked
    /// to span Settings, Medications, Dashboard, Onboarding, Charts, Mood and
    /// the metric-label data layer, plus every specifier shape.
    static let samples: [(en: String, de: String)] = [
        // Plain, high-traffic verbs / nouns
        ("Save", "Speichern"),
        ("Cancel", "Abbrechen"),
        ("Sign out", "Abmelden"),
        ("Delete account", "Konto löschen"),
        ("Account", "Konto"),
        ("Profile", "Profil"),
        ("Notifications", "Benachrichtigungen"),
        // Tab + navigation titles (collision-adjacent: Log/Erfassen, More/Mehr)
        ("Log", "Erfassen"),
        ("More", "Mehr"),
        ("Security", "Sicherheit"),
        // Metric labels feeding LocalizedStringKey bridges
        ("Weight", "Gewicht"),
        ("Blood pressure", "Blutdruck"),
        ("Steps", "Schritte"),
        ("Oxygen saturation", "Sauerstoffsättigung"),
        // Sentences with umlauts / sharp-s
        ("This action cannot be undone.", "Diese Aktion kann nicht rückgängig gemacht werden."),
        ("You can change this choice at any time in Settings.", "Du kannst diese Auswahl jederzeit in den Einstellungen ändern."),
        // Format-specifier keys — the make-or-break derivation cases
        ("Type %@ to confirm.", "Tippe %@ um zu bestätigen."),
        ("Deletion failed: %@", "Löschen fehlgeschlagen: %@"),
        ("1 year ago: %@, change %@ %@", "Vor 1 Jahr: %@, Veränderung %@ %@"),

        // ── v0.8.0 W5: previously-missed literals (had NO catalogue key) ──
        // The gap the v0.7.2 flip map never covered — nav titles, destructive /
        // primary buttons, onboarding CTAs, empty/error/loading copy,
        // notification action titles, a11y + short metric labels — sampled
        // across the heaviest areas (Insights, Coach, Notifications, Dashboard,
        // GLP1, Medications, Charts, Settings) plus every interpolation
        // specifier shape (%lld Int, %@ String, mixed, positional %N$ in de).

        // Tier-1 chrome the user reads first
        ("Correlations", "Zusammenhänge"),
        ("Stability", "Stabilität"),
        ("Ask the coach", "Frag den Coach"),
        ("Measurement", "Messung"),
        ("Delete", "Löschen"),
        ("Delete all", "Alle löschen"),
        ("Reset", "Zurücksetzen"),
        ("Reset to default", "Auf Standard zurücksetzen"),
        ("Later", "Später"),
        ("Add new passkey", "Neuen Passkey hinzufügen"),
        ("Severity", "Stärke"),
        ("Open coach", "Coach öffnen"),
        // Notification action titles (operator hard ship-criterion — must read
        // English in EN, German in DE)
        ("Skip today", "Heute überspringen"),
        ("Open", "Öffnen"),
        ("Taken", "Genommen"),
        // Short metric / axis / picker labels the flip skipped
        ("Mood", "Stimmung"),
        ("Day", "Tag"),
        ("Week", "Woche"),
        ("Month", "Monat"),
        ("Year", "Jahr"),
        ("Medication", "Medikament"),
        // Empty / error / loading state copy hit constantly
        ("No data", "Keine Daten"),
        ("Not enough data yet", "Noch nicht genug Daten"),
        ("Briefing loading …", "Briefing lädt …"),
        ("Coach is not available right now.", "Coach ist gerade nicht verfügbar."),
        ("No correlations yet", "Noch keine Zusammenhänge"),
        ("Detail view could not be loaded", "Detailansicht konnte nicht geladen werden"),
        // Medical-classification labels
        ("High-normal", "Hoch-normal"),
        ("Hypertension grade 1", "Hypertonie Grad 1"),
        // Interpolation: %lld (Int)
        ("%lld of 5", "%lld von 5"),
        ("%lld-day streak", "%lld-Tage-Serie"),
        ("%lld of 30 days in range", "%lld von 30 Tagen im Zielbereich"),
        // NOTE: "%lld entries" and "%@: Last measurement %lld days ago" USED to be
        // sampled here as flat interpolation, but audit-v0162 L10N-3 converted them
        // to plural `variations` / `substitutions` (one/other). Their compiled
        // format is now a device token (`%#@value@` / `%2$#@days@`) that only
        // resolves with a count argument — a bare `localizedString(forKey:)` returns
        // the template, which is CORRECT, not a raw-key leak. They are covered by
        // PluralVariationGuardTests instead; sampling them flat here is invalid.
        // Interpolation: %@ (String)
        ("Earned on %@", "Erreicht am %@"),
        ("%@ trend", "%@ Verlauf"),
        ("Personal record · %@", "Persönlicher Rekord · %@"),
        // Interpolation: mixed %@ + %lld, positional in de
        ("Calculated from %lld measurements over %lld days.", "Berechnet aus %1$lld Messungen über %2$lld Tage."),
        ("Mean %lld %@, min %lld, max %lld", "Mittel %1$lld %2$@, Min %3$lld, Max %4$lld")
    ]

    @Test("Every sampled key resolves to its English source under en — no empty / no MISSING")
    func englishResolvesToSource() throws {
        let en = try Self.lprojBundle(language: "en")
        for sample in Self.samples {
            let resolved = en.localizedString(forKey: sample.en, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "en build cannot resolve key: \(sample.en)")
            #expect(!resolved.isEmpty, "en value empty for key: \(sample.en)")
            #expect(resolved == sample.en, "en value drifted from source for key: \(sample.en) → \(resolved)")
        }
    }

    @Test("Every sampled key resolves to the original German under de — no raw-key leak")
    func germanResolvesToTranslation() throws {
        let de = try Self.lprojBundle(language: "de")
        for sample in Self.samples {
            let resolved = de.localizedString(forKey: sample.en, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "de build cannot resolve key: \(sample.en)")
            #expect(!resolved.isEmpty, "de value empty for key: \(sample.en)")
            #expect(
                resolved == sample.de,
                "de value is not the expected German (raw-key leak?) for key \(sample.en): got \(resolved)"
            )
        }
    }

    @Test("Translatable sampled keys actually differ from their German rendering")
    func germanDiffersFromEnglishSource() throws {
        // Every sampled key has a genuinely distinct German rendering; none are
        // proper-noun tokens that survive untranslated. Kept as a set so a
        // future sample addition (e.g. "bpm") can opt out without weakening the
        // assertion for the rest.
        let identicalByDesign: Set<String> = []
        let de = try Self.lprojBundle(language: "de")
        for sample in Self.samples where !identicalByDesign.contains(sample.en) {
            let german = de.localizedString(forKey: sample.en, value: "", table: nil)
            #expect(
                german != sample.en,
                "de rendering equals the English key — likely raw-key fallback for: \(sample.en)"
            )
        }
    }

    @Test("Format-specifier keys keep matching specifier counts across locales")
    func formatSpecifiersRoundTrip() throws {
        let en = try Self.lprojBundle(language: "en")
        let de = try Self.lprojBundle(language: "de")
        for sample in Self.samples {
            let enValue = en.localizedString(forKey: sample.en, value: "", table: nil)
            let deValue = de.localizedString(forKey: sample.en, value: "", table: nil)
            let enSpecifiers = Self.specifierCount(enValue)
            let deSpecifiers = Self.specifierCount(deValue)
            #expect(
                enSpecifiers == deSpecifiers,
                "specifier count diverges for \(sample.en): en=\(enSpecifiers) de=\(deSpecifiers)"
            )
        }
    }

    // MARK: - Helpers

    /// Counts `%@` and `%lld` (and positional `%1$@` …) placeholders so the de
    /// translation can substitute the same interpolations the code passes.
    private static func specifierCount(_ value: String) -> Int {
        let pattern = "%(?:[0-9]+\\$)?(?:@|lld|d|ld|f)"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return regex?.numberOfMatches(in: value, range: range) ?? 0
    }

    /// Resolves the compiled `<language>.lproj` bundle from the host app, the
    /// same table the running app consults. Mirrors `V052I18nKeysTests`.
    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw FlipTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum FlipTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
