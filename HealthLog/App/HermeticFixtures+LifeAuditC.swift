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
    /// (`src/lib/mental-health/instruments.ts`) for German, English and
    /// Korean, the English original with `validatedLocale: false` for any
    /// other app language, as the server does. The Korean answer ranges read
    /// "2~4회" where the server writes an en dash, which the visible-punctuation
    /// rule does not allow. This copy exists for the fixture server only
    /// (DEBUG); the app itself renders whatever the server sends.
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

        /// The fixture account's language follows the app's. The server holds
        /// validated wording for German and Korean (and English); Dutch reads
        /// the English original.
        private static var offeredLocale: String {
            AppLanguage.current.pick(de: "de", en: "en", nl: "en", ko: "ko")
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
            // `auditCCutoffSource`: S3 for German, KNHANES for Korean entries,
            // Bradley 2007 for every other language.
            let (cutoff, value) = switch entry.locale {
            case "de": (s3Female, 4)
            case "ko": (knhanesFemale, 4)
            default: (bradleyFemale, 3)
            }
            let above = total >= value
            return #"{"id":"\#(entry.id)","takenAt":"\#(entry.takenAt)","items":\#(entry.items),"totalScore":\#(total),"#
                + #""locale":"\#(entry.locale)","cutoff":\#(cutoff),"aboveCutoff":\#(above),"validatedLocale":true}"#
        }

        private static let s3Female = #"{"value":4,"sex":"female","source":"S3_ALCOHOL_DE","#
            + #""sourceLabel":"S3-Leitlinie Screening, Diagnose und Behandlung alkoholbezogener Störungen "#
            + #"(AWMF 076-001) (Deutschland)","sourceUrl":"https://alkoholleitlinie.de/diagnostik/test-audit-c/"}"#
        private static let knhanesFemale = #"{"value":4,"sex":"female","source":"KNHANES_KR","#
            + #""sourceLabel":"AUDIT-C cut-offs from the Korea National Health and Nutrition Examination Survey "#
            + #"(KNHANES) (대한민국)","sourceUrl":"https://pmc.ncbi.nlm.nih.gov/articles/PMC6039362"}"#
        private static let bradleyFemale = #"{"value":3,"sex":"female","source":"BRADLEY_2007","#
            + #""sourceLabel":"Bradley KA et al., Alcohol Clin Exp Res 2007;31(7):1208-1217 (United States)","#
            + #""sourceUrl":"https://onlinelibrary.wiley.com/doi/10.1111/j.1530-0277.2007.00403.x"}"#

        private static func instrument() -> String {
            let language = AppLanguage.current.rawValue
            let wording = AppLanguage.current.pick(de: german, en: english, nl: english, ko: korean)
            let drink = AppLanguage.current.pick(de: germanDrink, en: englishDrink, nl: dutchDrink, ko: koreanDrink)
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

        private static let korean: [(String, [String])] = [
            (
                "술을 마시는 횟수는 어느 정도입니까?",
                ["전혀 안 마신다", "한 달에 1회 이하", "한 달에 2~4회", "일주일에 2~3회", "일주일에 4회 이상"]
            ),
            (
                "술을 마시는 날은 보통 어느 정도를 마십니까?",
                [
                    "소주: 반 병 이하 / 기타 술: 1~2잔",
                    "소주: 1병 이하 / 기타 술: 3~4잔",
                    "소주: 1.5병 정도 / 기타 술: 5~6잔",
                    "소주: 2병 정도 / 기타 술: 7~9잔",
                    "소주: 2.5병 이상 / 기타 술: 10잔 이상"
                ]
            ),
            (
                "한 번의 술좌석에서 소주 1병을 초과해서 마시는 횟수는 어느 정도입니까?(기타 술은 표준 5잔 이상)",
                ["전혀 없다", "한 달에 1회 미만", "한 달에 1회정도", "일주일에 1회 정도", "거의 매일"]
            )
        ]

        private static let englishDrink = "One drink means a standard drink of about 10 g of pure alcohol, "
            + "for example 330 ml of beer at 5%, 140 ml of wine at 12% or 40 ml of spirits at 40%."
        private static let germanDrink = "Ein Glas Alkohol entspricht etwa 10 bis 12 g reinem Alkohol, "
            + "zum Beispiel 0,25 l Bier, 0,125 l Wein oder Sekt oder 4 cl Spirituosen."
        private static let dutchDrink = "Eén drankje is een standaardglas met ongeveer 10 g pure alcohol, "
            + "de WHO-definitie waarop deze vragen gebaseerd zijn."
        private static let koreanDrink = "표준 1잔: 양주잔으로 양주 1잔, 와인잔으로 와인 1잔, 막걸리 1사발이 각각 "
            + "표준 1잔이다. 맥주는 캔맥주 1캔 또는 작은 병맥주 1병이며 생맥주는 500 mL가 표준 1잔이다. "
            + "소주는 1/4병이 표준 1잔에 해당한다."
    }
#endif
