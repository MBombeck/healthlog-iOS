#if DEBUG
    import Foundation

    /// **The Today hero of the QA sweep.** Under `-uitest-sweep` the digest
    /// carries a three-line lead, the muted signal line, a score steady for
    /// five weeks, three facts (sleep with its comparison) and one hint
    /// with one action. With `-uitest-hero-dismissible` as well, the hint is a
    /// dismissible milestone instead, and dismissing it is answered, so a UI
    /// test can tell the dismiss mark from the card's own tap. Invented texts
    /// only, already in German as the server would send them. Last night's
    /// sleep is the sweep's own reading (432 minutes, `SweepFixtures`), so the
    /// hero, the sleep tile and the sleep page name the same night. The hint
    /// names the check-up `SweepWorldFixtures` serves as overdue, and an
    /// account without medications (`-uitest-sweep-nomeds`) gets no
    /// medication fact.
    enum TodayHeroFixtures {
        static let dismissibleArgument = "-uitest-hero-dismissible"

        private static var isDismissible: Bool {
            ProcessInfo.processInfo.arguments.contains(dismissibleArgument)
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            switch (method, path) {
            case ("GET", "/api/daily/digest"):
                (200, Data(digestJSON(hint: isDismissible ? milestoneHint : checkupHint).utf8))
            case ("POST", "/api/daily/digest/dismiss") where isDismissible:
                (200, Data(#"{"data":{"ok":true},"error":null}"#.utf8))
            default:
                nil
            }
        }

        private static let checkupHint = #"""
        {"kind":"preventive_care","itemKey":null,"title":"Vorsorge fällig",
         "body":"Die Messung deines Taillenumfangs ist seit zwei Wochen fällig.",
         "status":"warning",
         "actions":[{"labelKey":"daily.action.viewCheckups","intent":"checkup.view","href":null}],
         "moduleKey":null}
        """#

        /// `milestone.view` without an href opens the Insights overview.
        private static let milestoneHint = #"""
        {"kind":"milestone","itemKey":"milestone:steps:sweep","title":"Neuer Rekord",
         "body":"Gestern bist du so viele Schritte gegangen wie noch nie.",
         "status":"success",
         "actions":[{"labelKey":"daily.action.viewMilestone","intent":"milestone.view","href":null}],
         "moduleKey":null}
        """#

        private static let medicationFact = #"{"kind":"medication","label":"Medikamente","value":"2 von 3 genommen","href":null},"#

        private static func digestJSON(hint: String) -> String {
            let medication = HermeticUITestSupport.isSweepNoMedicationsActive ? "" : medicationFact
            return #"""
            {"generatedAt":"2026-11-13T06:00:00.000Z","phase":"final","sleepPending":false,
             "lead":{"text":"Heute zeigt sich ein ruhiger Tag: Dein Ruhepuls liegt bei 58 bpm und damit 2 bpm unter deinem 7- und 30-Tage-Mittel.","source":"reaction"},
             "signalLine":{"headline":null,"delta":"-2 bpm vs. dein 7- und 30-Tage-Mittel"},
             "score":{"value":78,"band":"green","delta":null,"steadyWeeks":5},
             "line":"","briefingLead":null,
             "today":[
            """# + medication + #"""
                      {"kind":"sleep","label":"Letzte Nacht","value":"7 Std. 12 Min., so lang wie sonst","href":null},
                      {"kind":"vitals","label":"Vitalwerte","value":"4 geprüft, alle im Bereich","href":null}],
             "worthALook":[
            """# + hint + "]}"
        }
    }
#endif
