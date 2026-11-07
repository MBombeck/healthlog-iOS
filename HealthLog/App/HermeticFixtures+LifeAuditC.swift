#if DEBUG
    import Foundation

    /// **AUDITC (1.5.0, #132) — AUDIT-C of the fixture server.**
    ///
    /// Part of `-uitest-life` (``LifeFixtures``): the read route carries an
    /// `auditC` block, `POST /api/anamnesis/audit-c` stores an entry and
    /// `DELETE /api/anamnesis/audit-c/{id}` removes one, so a UI test can
    /// answer, see the result and remove it again. The profile is a woman's,
    /// so the result carries a cut-off. The instrument stands in for the
    /// server's: the WHO wording of server v1.47.0
    /// (`src/lib/mental-health/instruments.ts`) for German and English, the
    /// English original with `validatedLocale: false` for any other app
    /// language, as the server does. This copy exists for the fixture server
    /// only (DEBUG); the app itself renders whatever the server sends.
    ///
    /// Every value is invented. Only called by ``LifeFixtures`` while it
    /// holds its lock, which also guards the state here.
    enum LifeAuditCFixtures {
        private struct Entry {
            let id: String
            let takenAt: String
            let items: [Int]
            let locale: String
        }

        /// One readable entry from long ago: the result shows, and the
        /// questionnaire is due again.
        private nonisolated(unsafe) static var entries: [Entry] = [
            Entry(id: "audit-c-seed", takenAt: "2025-06-10T08:00:00.000Z", items: [1, 1, 0], locale: offeredLocale)
        ]
        private nonisolated(unsafe) static var counter = 0

        /// The fixture account's language follows the app's.
        private static var offeredLocale: String {
            AppLanguage.current == .de ? "de" : "en"
        }

        static func route(path: String, method: String, body: [String: Any]) -> (Int, String)? {
            let base = "/api/anamnesis/audit-c"
            if method == "POST", path == base {
                return create(body)
            }
            if method == "DELETE", path.hasPrefix(base + "/") {
                let id = String(path.dropFirst(base.count + 1))
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return (404, "null") }
                entries.remove(at: index)
                return (200, #"{"id":"\#(id)","removedAt":"2026-11-05T09:00:00.000Z"}"#)
            }
            return nil
        }

        private static func create(_ body: [String: Any]) -> (Int, String) {
            guard let items = body["items"] as? [Int], items.count == 3,
                  items.allSatisfy({ (0 ... 4).contains($0) }),
                  body["locale"] as? String == offeredLocale else { return (422, "null") }
            counter += 1
            let stamp = (body["takenAt"] as? String) ?? "2026-11-05T09:00:00.000Z"
            let entry = Entry(id: "audit-c-\(counter)", takenAt: stamp, items: items, locale: offeredLocale)
            entries.insert(entry, at: 0)
            return (201, #"{"result":\#(result(entry))}"#)
        }

        // MARK: - Read

        static func json() -> String {
            let latest = entries.first.map(result) ?? "null"
            let history = entries.map {
                #"{"id":"\#($0.id)","takenAt":"\#($0.takenAt)","totalScore":\#($0.items.reduce(0, +))}"#
            }.joined(separator: ",")
            let due = entries.first.map { $0.takenAt < "2025-11-05" } ?? true
            return #"{"latest":\#(latest),"history":[\#(history)],"offerDue":\#(due),"instrument":\#(instrument())}"#
        }

        private static func result(_ entry: Entry) -> String {
            let total = entry.items.reduce(0, +)
            let german = entry.locale == "de"
            let cutoff = german ? s3Female : bradleyFemale
            let above = total >= (german ? 4 : 3)
            return #"{"id":"\#(entry.id)","takenAt":"\#(entry.takenAt)","items":\#(entry.items),"totalScore":\#(total),"#
                + #""locale":"\#(entry.locale)","cutoff":\#(cutoff),"aboveCutoff":\#(above),"validatedLocale":true}"#
        }

        private static let s3Female = #"{"value":4,"sex":"female","source":"S3_ALCOHOL_DE","#
            + #""sourceLabel":"S3-Leitlinie Screening, Diagnose und Behandlung alkoholbezogener Störungen "#
            + #"(AWMF 076-001) (Deutschland)","sourceUrl":"https://alkoholleitlinie.de/diagnostik/test-audit-c/"}"#
        private static let bradleyFemale = #"{"value":3,"sex":"female","source":"BRADLEY_2007","#
            + #""sourceLabel":"Bradley KA et al., Alcohol Clin Exp Res 2007;31(7):1208-1217 (United States)","#
            + #""sourceUrl":"https://onlinelibrary.wiley.com/doi/10.1111/j.1530-0277.2007.00403.x"}"#

        private static func instrument() -> String {
            let language = AppLanguage.current.rawValue
            let wording = offeredLocale == "de" ? german : english
            let drink = language == "de" ? germanDrink : (language == "nl" ? dutchDrink : englishDrink)
            let items = wording.map { stem, options in
                let list = options.enumerated().map { #"{"value":\#($0.offset),"label":"\#($0.element)"}"# }
                return #"{"stem":"\#(stem)","options":[\#(list.joined(separator: ","))]}"#
            }.joined(separator: ",")
            return #"{"items":[\#(items)],"locale":"\#(offeredLocale)","validatedLocale":\#(offeredLocale == language),"#
                + #""standardDrink":"\#(drink)","attribution":"As a WHO-approved instrument, the AUDIT is in the public domain."}"#
        }

        // MARK: - Server wording v1.47.0 (fixture copy)

        private static let english: [(String, [String])] = [
            (
                "How often do you have a drink containing alcohol?",
                ["Never", "Monthly or less", "2 to 4 times a month", "2 to 3 times a week", "4 or more times a week"]
            ),
            (
                "How many drinks containing alcohol do you have on a typical day when you are drinking?",
                ["1 or 2", "3 or 4", "5 or 6", "7, 8, or 9", "10 or more"]
            ),
            (
                "How often do you have six or more drinks on one occasion?",
                ["Never", "Less than monthly", "Monthly", "Weekly", "Daily or almost daily"]
            )
        ]

        private static let german: [(String, [String])] = [
            (
                "Wie oft nehmen Sie ein alkoholisches Getränk zu sich?",
                [
                    "Niemals",
                    "1 mal im Monat oder seltener",
                    "2 bis 4 mal im Monat",
                    "2 bis 3 mal pro Woche",
                    "4 mal oder mehrmals in der Woche"
                ]
            ),
            (
                "Wenn Sie alkoholische Getränke zu sich nehmen, wieviel trinken Sie dann typischerweise an einem Tag?",
                ["1 - 2", "3 - 4", "5 - 6", "7 - 9", "10 oder mehr"]
            ),
            (
                "Wie oft trinken Sie 6 oder mehr Gläser Alkohol bei einer Gelegenheit?",
                ["Niemals", "Seltener als 1 mal im Monat", "1 mal im Monat", "1 mal pro Woche", "Täglich oder fast täglich"]
            )
        ]

        private static let englishDrink = "One drink means a standard drink of about 10 g of pure alcohol, "
            + "for example 330 ml of beer at 5%, 140 ml of wine at 12% or 40 ml of spirits at 40%."
        private static let germanDrink = "Ein Glas Alkohol entspricht etwa 10 bis 12 g reinem Alkohol, "
            + "zum Beispiel 0,25 l Bier, 0,125 l Wein oder Sekt oder 4 cl Spirituosen."
        private static let dutchDrink = "Eén drankje is een standaardglas met ongeveer 10 g pure alcohol, "
            + "de WHO-definitie waarop deze vragen gebaseerd zijn."
    }
#endif
