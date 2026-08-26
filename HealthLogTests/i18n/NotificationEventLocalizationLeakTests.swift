import Foundation
@testable import HealthLog
import Testing

/// v0153 INV-D L3 — notification toggle title/hint localization gate.
///
/// The per-event notification toggle list is server-driven (`payload.eventTypes`,
/// runtime). Before this fix the `NotificationEventLocalization.title(for:)`
/// `switch` had a `default` branch that English-title-cased any unrecognised
/// SCREAMING_SNAKE server code:
///
/// ```swift
/// default: eventType.replacingOccurrences(of: "_", with: " ").capitalized
/// ```
///
/// Newer server categories (`COACH_NUDGE`, `CYCLE_PERIOD_CONFIRM`, …) fell
/// through it, so the German build rendered "Coach Nudge" / "Cycle Period
/// Confirm" — English leaking verbatim. These tests pin two guarantees:
///   1. The known coach/cycle codes now hit explicit `case`s and resolve to a
///      registered, translated string (not the raw Title-Cased code).
///   2. An unknown code no longer Title-Cases — the hardened `default` returns
///      the localized generic "Notification" / "Benachrichtigung".
@Suite("NotificationEventLocalization — no English-title-case leak")
struct NotificationEventLocalizationLeakTests {
    // MARK: - Known codes resolve to a registered string (not raw Title-Case)

    /// (server code, the raw Title-Cased form the old `default` would emit).
    /// The title must NOT equal that raw form — it must be a real translation.
    static let knownCodes: [(code: String, titleCased: String)] = [
        ("COACH_NUDGE", "Coach Nudge"),
        ("CYCLE_PERIOD_CONFIRM", "Cycle Period Confirm"),
        ("CYCLE_PERIOD_PREDICTED", "Cycle Period Predicted"),
        ("CYCLE_FERTILE_WINDOW", "Cycle Fertile Window"),
        ("CYCLE_OVULATION", "Cycle Ovulation"),
        ("REST_DAY", "Rest Day"),
        ("VORSORGE_DUE", "Vorsorge Due")
    ]

    @Test("Known coach/cycle codes no longer fall through to Title-Cased default")
    func knownCodesAreNotTitleCased() {
        for sample in Self.knownCodes {
            let title = NotificationEventLocalization.title(for: sample.code)
            #expect(
                title != sample.titleCased,
                "code \(sample.code) still renders the raw Title-Cased default: \(title)"
            )
            #expect(!title.isEmpty, "empty title for \(sample.code)")
            // A genuine translation, not the raw SCREAMING_SNAKE code either.
            #expect(title != sample.code, "code \(sample.code) leaked its raw identifier")
        }
    }

    /// **UI-Standard R1/R2 (U6) — die Ereignis-Zeile trägt keinen Hint mehr.**
    ///
    /// Diese Prüfung stand vorher auf dem Kopf: sie verlangte, dass jeder neue
    /// Server-Code eine Unterzeile *hat*. Die Unterzeilen sagten aber ihren
    /// eigenen Zeilentitel noch einmal („Eisprung" → „Rund um deinen geschätzten
    /// Eisprung-Tag."), und genau das verbietet R2 (Tautologie, Abdeck-Probe).
    /// `DAILY_BRIEFING` ist die einzige Ausnahme: „Tägliches Briefing" nennt
    /// weder Takt noch Tageszeit, der Hint tut es.
    ///
    /// Die Leak-Absicherung, um die es dieser Suite geht, hängt am **Titel** —
    /// die Tests darüber und darunter prüfen sie unverändert.
    @Test("Ereignis-Zeilen tragen keine tautologische Unterzeile mehr — nur das Tages-Briefing erklärt Takt und Zeitpunkt")
    func onlyDailyBriefingCarriesAHint() {
        for sample in Self.knownCodes {
            #expect(
                NotificationEventLocalization.hint(for: sample.code) == nil,
                "\(sample.code) trägt wieder eine Unterzeile — R2 verbietet die Titel-Umformulierung"
            )
        }
        #expect(NotificationEventLocalization.hint(for: "DAILY_BRIEFING") != nil)
        // R7 — der Stimmungs-Hint nannte „Abends 22:00"; die Uhrzeit ist
        // einstellbar, die Aussage lebt jetzt an der Stimmungs-Karte.
        #expect(NotificationEventLocalization.hint(for: "MOOD_REMINDER") == nil)
    }

    // MARK: - Hardened default

    @Test("Unknown server code does not English-title-case — returns the generic label")
    func unknownCodeIsNotTitleCased() {
        // A plausible future server code the app has never seen.
        let unknown = "BRAND_NEW_SERVER_CATEGORY"
        let title = NotificationEventLocalization.title(for: unknown)
        let oldDefault = unknown.replacingOccurrences(of: "_", with: " ").capitalized
        #expect(
            title != oldDefault,
            "hardened default regressed — still Title-Cases unknown codes: \(title)"
        )
        // The generic fallback (en source "Notification").
        #expect(title == String(localized: "Notification"))
        // Unknown codes intentionally carry no hint.
        #expect(NotificationEventLocalization.hint(for: unknown) == nil)
    }

    // MARK: - German bundle resolution (the leak the operator reported)

    @Test("New codes resolve to their German titles in the de bundle — no English leak")
    func germanTitlesResolve() throws {
        let de = try Self.lprojBundle(language: "de")
        let expected: [(en: String, de: String)] = [
            ("Coach nudge", "Coach-Impuls"),
            ("Confirm period", "Periode bestätigen"),
            ("Notification", "Benachrichtigung")
        ]
        for sample in expected {
            let resolved = de.localizedString(forKey: sample.en, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "de build cannot resolve key: \(sample.en)")
            #expect(
                resolved == sample.de,
                "de value is not the expected German for \(sample.en): got \(resolved)"
            )
        }
    }

    // MARK: - Helpers

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw LeakTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum LeakTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
