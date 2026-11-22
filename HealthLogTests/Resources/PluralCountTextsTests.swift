import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Counted texts resolve to their singular at 1 and their plural at 0 and 2,
/// in German, English and Dutch, through the same path the screens use:
/// `String(format:)` over the catalog value for the format keys, an
/// interpolated `LocalizedStringResource` for the keys that carry their
/// placeholders in the key itself.
@Suite("Counted texts carry singular and plural forms")
struct PluralCountTextsTests {
    enum Mode: Sendable {
        case format
        case resource
    }

    enum Arg: Sendable {
        case count
        case text(String)
        case number(Int)
    }

    /// One key: how the screen resolves it, its arguments, and the expected
    /// text at 0, 1 and 2 in each language.
    struct Row: Sendable, CustomTestStringConvertible {
        let key: String
        let mode: Mode
        let args: [Arg]
        let expected: [String: [String]]

        init(_ key: String, _ mode: Mode, _ args: [Arg], de: [String], en: [String], nl: [String]) {
            self.key = key
            self.mode = mode
            self.args = args
            expected = ["de": de, "en": en, "nl": nl]
        }

        var testDescription: String {
            key
        }
    }

    static func resolve(_ row: Row, language: String, count: Int) throws -> String {
        switch row.mode {
        case .format:
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let format = bundle.localizedString(forKey: row.key, value: "MISSING", table: nil)
            let values: [CVarArg] = row.args.map { arg in
                switch arg {
                case .count: count
                case let .text(text): text
                case let .number(number): number
                }
            }
            return String(format: format, arguments: values)
        case .resource:
            var resource = LocalizedStringResource(interpolated(row, count: count))
            resource.locale = Locale(identifier: language)
            return String(localized: resource)
        }
    }

    /// Rebuilds `"key \(a) \(b)"` from the key's literal parts and the row's
    /// arguments, so the lookup key is exactly the catalog key.
    static func interpolated(_ row: Row, count: Int) -> String.LocalizationValue {
        var interpolation = String.LocalizationValue.StringInterpolation(
            literalCapacity: row.key.count,
            interpolationCount: row.args.count
        )
        var args = row.args.makeIterator()
        func appendNext() {
            switch args.next() {
            case .count?: interpolation.appendInterpolation(count)
            case let .text(text)?: interpolation.appendInterpolation(text)
            case let .number(number)?: interpolation.appendInterpolation(number)
            case nil: break
            }
        }
        for (index, piece) in row.key.components(separatedBy: " ").enumerated() {
            if index > 0 { interpolation.appendLiteral(" ") }
            if piece == "%lld" || piece == "%@" {
                appendNext()
            } else if piece == "%@," {
                appendNext()
                interpolation.appendLiteral(",")
            } else if piece.hasSuffix("%lld") {
                // `labs.scan.saved.%lld`: the placeholder is glued to the key.
                interpolation.appendLiteral(String(piece.dropLast(4)))
                appendNext()
            } else {
                interpolation.appendLiteral(piece)
            }
        }
        return String.LocalizationValue(stringInterpolation: interpolation)
    }

    @Test("Each counted text reads right at 0, 1 and 2 in de, en and nl", arguments: Self.rows)
    func countedText(_ row: Row) throws {
        for language in ["de", "en", "nl"] {
            let expected = try #require(row.expected[language])
            #expect(expected.count == 3, "\(row.key) \(language)")
            for (count, text) in expected.enumerated() {
                #expect(try Self.resolve(row, language: language, count: count) == text, "\(row.key) \(language) \(count)")
            }
        }
    }

    @Test("The table covers every key that gained a singular")
    func coverage() {
        #expect(Set(Self.rows.map(\.key)).count == 28)
    }

    static var rows: [Row] {
        pluralRows
    }
}

/// The expected texts, kept outside the suite type so its body stays short.
private let pluralRows: [PluralCountTextsTests.Row] = [
    .init(
        "cycle.home.center.inDays", .format, [.count],
        de: ["in 0 Tagen", "in 1 Tag", "in 2 Tagen"],
        en: ["in 0 days", "in 1 day", "in 2 days"],
        nl: ["over 0 dagen", "over 1 dag", "over 2 dagen"]
    ),
    .init(
        "cycle.home.center.overdue.title", .format, [.count],
        de: ["0 Tage überfällig", "1 Tag überfällig", "2 Tage überfällig"],
        en: ["0 days overdue", "1 day overdue", "2 days overdue"],
        nl: ["0 dagen te laat", "1 dag te laat", "2 dagen te laat"]
    ),
    .init(
        "cycle.insights.tile.inDays", .format, [.count],
        de: ["Periode in ~0 Tagen", "Periode in ~1 Tag", "Periode in ~2 Tagen"],
        en: ["Period in ~0 days", "Period in ~1 day", "Period in ~2 days"],
        nl: ["Menstruatie over ~0 dagen", "Menstruatie over ~1 dag", "Menstruatie over ~2 dagen"]
    ),
    .init(
        "customMetric.values.count %lld", .resource, [.count],
        de: ["0 Werte", "1 Wert", "2 Werte"],
        en: ["0 values", "1 value", "2 values"],
        nl: ["0 waarden", "1 waarde", "2 waarden"]
    ),
    .init(
        "labs.scan.saved.%lld", .resource, [.count],
        de: ["0 Werte gespeichert", "1 Wert gespeichert", "2 Werte gespeichert"],
        en: ["Saved 0 readings", "Saved 1 reading", "Saved 2 readings"],
        nl: ["0 metingen opgeslagen", "1 meting opgeslagen", "2 metingen opgeslagen"]
    ),
    .init(
        "reminders.schedule.everyNDays", .format, [.count],
        de: ["Alle 0 Tage", "Jeden Tag", "Alle 2 Tage"],
        en: ["Every 0 days", "Every day", "Every 2 days"],
        nl: ["Elke 0 dagen", "Elke dag", "Elke 2 dagen"]
    ),
    .init(
        "vorsorge.card.cadence.everyNDays", .format, [.count],
        de: ["Alle 0 Tage", "Jeden Tag", "Alle 2 Tage"],
        en: ["Every 0 days", "Every day", "Every 2 days"],
        nl: ["Elke 0 dagen", "Elke dag", "Elke 2 dagen"]
    ),
    .init(
        "sync.footer.failed_drop", .format, [.count],
        de: [
            "0 Einträge konnten nicht übermittelt werden",
            "1 Eintrag konnte nicht übermittelt werden",
            "2 Einträge konnten nicht übermittelt werden"
        ],
        en: ["0 entries couldn't be uploaded", "1 entry couldn't be uploaded", "2 entries couldn't be uploaded"],
        nl: [
            "0 registraties konden niet worden geüpload",
            "1 registratie kon niet worden geüpload",
            "2 registraties konden niet worden geüpload"
        ]
    ),
    .init(
        "documents.detail.labValuesLink", .format, [.count],
        de: ["0 Laborwerte ansehen", "1 Laborwert ansehen", "2 Laborwerte ansehen"],
        en: ["View 0 lab values", "View 1 lab value", "View 2 lab values"],
        nl: ["0 labwaarden bekijken", "1 labwaarde bekijken", "2 labwaarden bekijken"]
    ),
    .init(
        "mood.tags.manage.group.tagCount", .format, [.count],
        de: ["0 Tags", "1 Tag", "2 Tags"],
        en: ["0 tags", "1 tag", "2 tags"],
        nl: ["0 tags", "1 tag", "2 tags"]
    ),
    .init(
        "mood.tags.manage.usage", .format, [.count],
        de: ["In 0 Einträgen verwendet", "In 1 Eintrag verwendet", "In 2 Einträgen verwendet"],
        en: ["Used in 0 entries", "Used in 1 entry", "Used in 2 entries"],
        nl: ["Gebruikt in 0 registraties", "Gebruikt in 1 registratie", "Gebruikt in 2 registraties"]
    ),
    .init(
        "mood.tags.manage.purge.body", .format, [.count],
        de: [
            "Der Tag wird aus 0 bisherigen Einträgen entfernt. Das lässt sich nicht rückgängig machen.",
            "Der Tag wird aus 1 bisherigen Eintrag entfernt. Das lässt sich nicht rückgängig machen.",
            "Der Tag wird aus 2 bisherigen Einträgen entfernt. Das lässt sich nicht rückgängig machen."
        ],
        en: [
            "This removes the tag from 0 past entries. This cannot be undone.",
            "This removes the tag from 1 past entry. This cannot be undone.",
            "This removes the tag from 2 past entries. This cannot be undone."
        ],
        nl: [
            "Hiermee wordt de tag uit 0 eerdere registraties verwijderd. Dit kan niet ongedaan worden gemaakt.",
            "Hiermee wordt de tag uit 1 eerdere registratie verwijderd. Dit kan niet ongedaan worden gemaakt.",
            "Hiermee wordt de tag uit 2 eerdere registraties verwijderd. Dit kan niet ongedaan worden gemaakt."
        ]
    ),
    .init(
        "mood.tags.manage.group.delete.body", .format, [.count],
        de: [
            "0 eigene Tags werden in „Eigene Tags“ verschoben. Katalog-Tags kehren in ihre ursprüngliche Gruppe zurück. Einträge bleiben erhalten.",
            "1 eigener Tag wird in „Eigene Tags“ verschoben. Katalog-Tags kehren in ihre ursprüngliche Gruppe zurück. Einträge bleiben erhalten.",
            "2 eigene Tags werden in „Eigene Tags“ verschoben. Katalog-Tags kehren in ihre ursprüngliche Gruppe zurück. Einträge bleiben erhalten."
        ],
        en: [
            "0 custom tags will move to Custom. Catalogue tags return to their original group. Entries remain intact.",
            "1 custom tag will move to Custom. Catalogue tags return to their original group. Entries remain intact.",
            "2 custom tags will move to Custom. Catalogue tags return to their original group. Entries remain intact."
        ],
        nl: [
            "0 eigen tags worden verplaatst naar Eigen. Catalogustags gaan terug naar hun oorspronkelijke groep. Registraties blijven behouden.",
            "1 eigen tag wordt verplaatst naar Eigen. Catalogustags gaan terug naar hun oorspronkelijke groep. Registraties blijven behouden.",
            "2 eigen tags worden verplaatst naar Eigen. Catalogustags gaan terug naar hun oorspronkelijke groep. Registraties blijven behouden."
        ]
    ),
    .init(
        "settings.security.twoFactor.recoveryRemaining %lld", .resource, [.count],
        de: ["Noch 0 Wiederherstellungscodes übrig", "Noch 1 Wiederherstellungscode übrig", "Noch 2 Wiederherstellungscodes übrig"],
        en: ["0 recovery codes remaining", "1 recovery code remaining", "2 recovery codes remaining"],
        nl: ["Nog 0 herstelcodes over", "Nog 1 herstelcode over", "Nog 2 herstelcodes over"]
    ),
    .init(
        "sharing.unified.dropped", .format, [.count],
        de: [
            "0 Einträge wurden entfernt, weil diese Ausgabeform sie nicht tragen darf.",
            "1 Eintrag wurde entfernt, weil diese Ausgabeform ihn nicht tragen darf.",
            "2 Einträge wurden entfernt, weil diese Ausgabeform sie nicht tragen darf."
        ],
        en: [
            "0 entries were removed because this output form may not carry them.",
            "1 entry was removed because this output form may not carry it.",
            "2 entries were removed because this output form may not carry them."
        ],
        nl: [
            "0 registraties zijn verwijderd omdat deze uitvoervorm ze niet mag bevatten.",
            "1 registratie is verwijderd omdat deze uitvoervorm die niet mag bevatten.",
            "2 registraties zijn verwijderd omdat deze uitvoervorm ze niet mag bevatten."
        ]
    ),
    .init(
        "report.selection.notice.dropped", .format, [.count],
        de: [
            "0 gespeicherte Einträge gibt es auf diesem Server nicht mehr und wurden entfernt.",
            "1 gespeicherten Eintrag gibt es auf diesem Server nicht mehr, er wurde entfernt.",
            "2 gespeicherte Einträge gibt es auf diesem Server nicht mehr und wurden entfernt."
        ],
        en: [
            "0 saved entries no longer exist on this server and were removed.",
            "1 saved entry no longer exists on this server and was removed.",
            "2 saved entries no longer exist on this server and were removed."
        ],
        nl: [
            "0 bewaarde items bestaan niet meer op deze server en zijn verwijderd.",
            "1 bewaard item bestaat niet meer op deze server en is verwijderd.",
            "2 bewaarde items bestaan niet meer op deze server en zijn verwijderd."
        ]
    ),
    .init(
        "sleep.composition.a11y.minutes", .format, [.count],
        de: ["0 Minuten", "1 Minute", "2 Minuten"],
        en: ["0 minutes", "1 minute", "2 minutes"],
        nl: ["0 minuten", "1 minuut", "2 minuten"]
    ),
    .init(
        "≈ %d weeks of supply", .format, [.count],
        de: ["≈ 0 Wochen Vorrat", "≈ 1 Woche Vorrat", "≈ 2 Wochen Vorrat"],
        en: ["≈ 0 weeks of supply", "≈ 1 week of supply", "≈ 2 weeks of supply"],
        nl: ["≈ 0 weken voorraad", "≈ 1 week voorraad", "≈ 2 weken voorraad"]
    ),
    .init(
        "%d Pens", .format, [.count],
        de: ["0 Pens", "1 Pen", "2 Pens"],
        en: ["0 Pens", "1 Pen", "2 Pens"],
        nl: ["0 pennen", "1 pen", "2 pennen"]
    ),
    .init(
        "integration.sync.rateLimited.seconds", .format, [.count],
        de: [
            "Das hast du gerade eben schon gemacht. In 0 Sekunden geht es wieder.",
            "Das hast du gerade eben schon gemacht. In 1 Sekunde geht es wieder.",
            "Das hast du gerade eben schon gemacht. In 2 Sekunden geht es wieder."
        ],
        en: [
            "You just did that. It'll work again in 0 seconds.",
            "You just did that. It'll work again in 1 second.",
            "You just did that. It'll work again in 2 seconds."
        ],
        nl: [
            "Dat heb je net al gedaan. Over 0 seconden werkt het weer.",
            "Dat heb je net al gedaan. Over 1 seconde werkt het weer.",
            "Dat heb je net al gedaan. Over 2 seconden werkt het weer."
        ]
    ),
    .init(
        "today.hero.steady %lld", .resource, [.count],
        de: ["seit 0 Wochen stabil", "seit 1 Woche stabil", "seit 2 Wochen stabil"],
        en: ["steady for 0 weeks", "steady for 1 week", "steady for 2 weeks"],
        nl: ["al 0 weken stabiel", "al 1 week stabiel", "al 2 weken stabiel"]
    ),
    .init(
        "today.hero.steadyAtLeast %lld", .resource, [.count],
        de: ["seit mindestens 0 Wochen stabil", "seit mindestens 1 Woche stabil", "seit mindestens 2 Wochen stabil"],
        en: ["steady for at least 0 weeks", "steady for at least 1 week", "steady for at least 2 weeks"],
        nl: ["al minstens 0 weken stabiel", "al minstens 1 week stabiel", "al minstens 2 weken stabiel"]
    ),
    .init(
        "med.lowstock.push.body", .format, [.text("Lisinopril"), .count],
        de: [
            "Lisinopril reicht noch ≈ 0 Tage. Zeit, Nachschub zu besorgen.",
            "Lisinopril reicht noch ≈ 1 Tag. Zeit, Nachschub zu besorgen.",
            "Lisinopril reicht noch ≈ 2 Tage. Zeit, Nachschub zu besorgen."
        ],
        en: [
            "Lisinopril lasts ≈ 0 more days. Time to restock.",
            "Lisinopril lasts ≈ 1 more day. Time to restock.",
            "Lisinopril lasts ≈ 2 more days. Time to restock."
        ],
        nl: [
            "Lisinopril is nog ≈ 0 dagen voorradig. Tijd om aan te vullen.",
            "Lisinopril is nog ≈ 1 dag voorradig. Tijd om aan te vullen.",
            "Lisinopril is nog ≈ 2 dagen voorradig. Tijd om aan te vullen."
        ]
    ),
    .init(
        "records.streak.slot %@ %lld", .resource, [.text("10000"), .count],
        de: ["Längste Serie ≥ 10000 (0 Tage)", "Längste Serie ≥ 10000 (1 Tag)", "Längste Serie ≥ 10000 (2 Tage)"],
        en: ["Longest streak ≥ 10000 (0 days)", "Longest streak ≥ 10000 (1 day)", "Longest streak ≥ 10000 (2 days)"],
        nl: ["Langste reeks ≥ 10000 (0 dagen)", "Langste reeks ≥ 10000 (1 dag)", "Langste reeks ≥ 10000 (2 dagen)"]
    ),
    .init(
        "sleep.average.learning %lld %lld", .resource, [.count, .number(5)],
        de: [
            "Dein Schlaf wird noch erfasst: 0 Nächte bisher, noch 5 für einen verlässlichen Durchschnitt.",
            "Dein Schlaf wird noch erfasst: 1 Nacht bisher, noch 5 für einen verlässlichen Durchschnitt.",
            "Dein Schlaf wird noch erfasst: 2 Nächte bisher, noch 5 für einen verlässlichen Durchschnitt."
        ],
        en: [
            "Still learning your sleep: 0 nights so far, 5 more for a reliable average.",
            "Still learning your sleep: 1 night so far, 5 more for a reliable average.",
            "Still learning your sleep: 2 nights so far, 5 more for a reliable average."
        ],
        nl: [
            "Je slaap wordt nog in kaart gebracht: tot nu toe 0 nachten, nog 5 nodig voor een betrouwbaar gemiddelde.",
            "Je slaap wordt nog in kaart gebracht: tot nu toe 1 nacht, nog 5 nodig voor een betrouwbaar gemiddelde.",
            "Je slaap wordt nog in kaart gebracht: tot nu toe 2 nachten, nog 5 nodig voor een betrouwbaar gemiddelde."
        ]
    ),
    .init(
        "sleep.debt.learning %lld %lld", .resource, [.count, .number(5)],
        de: [
            "Dein Schlaf wird noch erfasst: 0 Nächte bisher, noch 5 für eine verlässliche Bilanz.",
            "Dein Schlaf wird noch erfasst: 1 Nacht bisher, noch 5 für eine verlässliche Bilanz.",
            "Dein Schlaf wird noch erfasst: 2 Nächte bisher, noch 5 für eine verlässliche Bilanz."
        ],
        en: [
            "Still learning your sleep: 0 nights so far, 5 more to read a reliable balance.",
            "Still learning your sleep: 1 night so far, 5 more to read a reliable balance.",
            "Still learning your sleep: 2 nights so far, 5 more to read a reliable balance."
        ],
        nl: [
            "Je slaap wordt nog in kaart gebracht: tot nu toe 0 nachten, nog 5 nodig voor een betrouwbaar saldo.",
            "Je slaap wordt nog in kaart gebracht: tot nu toe 1 nacht, nog 5 nodig voor een betrouwbaar saldo.",
            "Je slaap wordt nog in kaart gebracht: tot nu toe 2 nachten, nog 5 nodig voor een betrouwbaar saldo."
        ]
    ),
    .init(
        "%@, %lld entries", .resource, [.text("Apple Health"), .count],
        de: ["Apple Health, 0 Einträge", "Apple Health, 1 Eintrag", "Apple Health, 2 Einträge"],
        en: ["Apple Health, 0 entries", "Apple Health, 1 entry", "Apple Health, 2 entries"],
        nl: ["Apple Health, 0 registraties", "Apple Health, 1 registratie", "Apple Health, 2 registraties"]
    ),
    .init(
        "measurements.bucket.a11y %@ %@ %@ %lld %@ %@", .resource, [
            .text("W45"),
            .text("72"),
            .text("kg"),
            .count,
            .text("71"),
            .text("73")
        ],
        de: [
            "W45, Ø 72 kg, 0 Einträge, Min 71, Max 73",
            "W45, Ø 72 kg, 1 Eintrag, Min 71, Max 73",
            "W45, Ø 72 kg, 2 Einträge, Min 71, Max 73"
        ],
        en: [
            "W45, average 72 kg, 0 entries, min 71, max 73",
            "W45, average 72 kg, 1 entry, min 71, max 73",
            "W45, average 72 kg, 2 entries, min 71, max 73"
        ],
        nl: [
            "W45, gemiddeld 72 kg, 0 registraties, min. 71, max. 73",
            "W45, gemiddeld 72 kg, 1 registratie, min. 71, max. 73",
            "W45, gemiddeld 72 kg, 2 registraties, min. 71, max. 73"
        ]
    )
]
