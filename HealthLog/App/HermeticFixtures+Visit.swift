#if DEBUG
    import Foundation

    /// **1.5 VISIT — a booked visit with its preparation window.**
    /// Under `-uitest-visit` the fixture server answers `GET /api/encounters`
    /// with one planned visit in thirteen days (Hautpraxis am Markt,
    /// Dermatologie), its window starting at the last visit with the same
    /// practitioner 85 days ago, and `GET /api/day/notable` with that window:
    /// a dose change, an illness that began, a highest weight and a pulse gap,
    /// plus a first reading the section leaves out. With `-uitest-visit-plain`
    /// as well, the visit comes without `preparation` (a server before
    /// v1.43.11). Without the argument the sweep's `{}` means no visit. Dates
    /// are relative to today, so the visit is always ahead. Invented values only.
    enum VisitFixtures {
        static let argument = "-uitest-visit"
        static let plainArgument = "-uitest-visit-plain"
        /// POLISH-A A8 — the last visit at the practice lies 900 days back, so
        /// a v1.47.1 server caps the window at 730 days and says `capped`.
        static let cappedArgument = "-uitest-visit-capped"

        private static var isCapped: Bool {
            ProcessInfo.processInfo.arguments.contains(cappedArgument)
        }

        /// First day of the window: 85 days back, or the first of the last 730
        /// days ending on the visit's day when capped.
        private static var fromOffset: Int {
            isCapped ? 13 - 729 : -85
        }

        static func response(forPath path: String) -> (status: Int, body: Data)? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains(argument) else { return nil }
            switch path {
            case "/api/encounters":
                return (200, Data(encounters(withPreparation: !arguments.contains(plainArgument)).utf8))
            case "/api/day/notable":
                return (200, Data(notable.utf8))
            default:
                return nil
            }
        }

        private static let calendar = Calendar.current

        private static func dayKey(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now)) ?? .now
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        private static func instant(dayOffset: Int, hour: Int, minute: Int) -> String {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: .now)) ?? .now
            let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return ISO8601DateFormatter().string(from: date)
        }

        private static func encounters(withPreparation: Bool) -> String {
            let preparation = withPreparation
                ? #""preparation":{"from":"\#(dayKey(fromOffset))","to":"\#(dayKey(13))","basis":"practitioner","#
                + (isCapped ? #""capped":true,"# : "")
                + #""since":{"id":"enc_prev","occurredAt":"\#(instant(dayOffset: isCapped ? -900 : -85, hour: 10, minute: 0))","kind":"SPECIALIST","#
                + #""practitionerName":"Dr. Weber","specialty":"Dermatologie"}},"#
                : ""
            return #"{"data":{"upcoming":[{"id":"enc_next","occurredAt":"\#(instant(dayOffset: 13, hour: 9, minute: 30))","#
                + #""status":"PLANNED","kind":"SPECIALIST","practitioner":{"id":"p1","name":"Dr. Weber","specialty":"Dermatologie","#
                + #""practice":"Hautpraxis am Markt","location":null,"phone":null,"note":null,"createdAt":"2026-01-01T00:00:00.000Z","#
                + #""updatedAt":"2026-01-01T00:00:00.000Z"},"reason":null,"outcome":null,"bodySite":null,"laterality":null,"#
                + #""reminderNextDueAt":null,"links":{"documents":[],"labResults":[],"conditions":[]},\#(preparation)"#
                + #""createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-01T00:00:00.000Z"}],"past":[]},"#
                + #""error":null,"meta":{}}"#
        }

        private static var notable: String {
            #"{"data":{"from":"\#(dayKey(fromOffset))","to":"\#(dayKey(0))","anchor":"nextVisit","observations":["#
                + #"{"date":"\#(dayKey(-40))","kind":"extremeHigh","type":"WEIGHT","params":{"since":"\#(dayKey(-300))","value":82.4}},"#
                + #"{"date":"\#(dayKey(-20))","kind":"gap","type":"PULSE","params":{"days":16}},"#
                + #"{"date":"\#(dayKey(-70))","kind":"firstValue","type":"BODY_TEMPERATURE","params":{"type":"BODY_TEMPERATURE"}}],"#
                + #""changes":[{"date":"\#(dayKey(-60))","kind":"doseChange","section":"medications","id":"m1","title":"Lisinopril 5 mg","count":1,"href":null},"#
                + #"{"date":"\#(dayKey(-30))","kind":"illnessOnset","section":"illness","id":"e1","title":"Erkältung","count":1,"href":null}]},"#
                + #""error":null,"meta":{}}"#
        }
    }
#endif
