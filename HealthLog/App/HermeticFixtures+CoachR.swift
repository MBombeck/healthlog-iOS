#if DEBUG
    import Foundation

    /// **1.5 COACH-R — a v1.41 Coach for the screenshot sweep.** Under
    /// `-uitest-coach-r` the fixture server publishes `coachReasoning` on
    /// `/api/auth/me` and answers a Coach turn with the live trail, a plan
    /// proposal and a trail to open. The turn's stream is split: the first
    /// `activity` frames arrive at once, the answer after ``tailDelay`` seconds,
    /// so the sweep can photograph the running answer with its status line.
    /// `nil` everywhere without the argument.
    enum CoachRFixtures {
        static let argument = "-uitest-coach-r"
        static let tailDelay: TimeInterval = 12

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        /// The server localizes these labels and the answer per request, in
        /// the request's language (`messages/<language>.json` for the labels).
        private static var language: AppLanguage {
            AppLanguage.current
        }

        static func response(
            forPath path: String,
            method: String,
            base: () -> (status: Int, body: Data)
        ) -> (status: Int, body: Data)? {
            guard isActive else { return nil }
            switch (method, path) {
            case ("GET", "/api/auth/me"):
                return (200, meWithReasoning(base().body))
            case ("GET", "/api/insights/chat/c-hermetic/messages/m-hermetic/trail"):
                return (200, Data(trailJSON.utf8))
            case ("POST", "/api/insights/chat"):
                let (head, tail) = streamParts
                return (200, Data((head + tail).utf8))
            default:
                return nil
            }
        }

        /// The chat stream in two parts: head now, tail after ``tailDelay``.
        static func split(forPath path: String, method: String) -> (head: Data, tail: Data)? {
            guard isActive, method == "POST", path == "/api/insights/chat" else { return nil }
            let (head, tail) = streamParts
            return (Data(head.utf8), Data(tail.utf8))
        }

        private static func meWithReasoning(_ body: Data) -> Data {
            guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
            let reasoning: [String: Any] = [
                "level": "medium", "preference": "medium", "maxLevel": "high",
                "available": true, "offIsReal": true, "source": "user"
            ]
            if var data = object["data"] as? [String: Any] {
                data["coachReasoning"] = reasoning
                object["data"] = data
            } else {
                object["coachReasoning"] = reasoning
            }
            return (try? JSONSerialization.data(withJSONObject: object)) ?? body
        }

        private static func frame(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return "data: " + (String(data: data, encoding: .utf8) ?? "{}") + "\n\n"
        }

        private static func activity(_ id: String, _ phase: String, _ status: String, _ label: String, title: String? = nil) -> String {
            var entry: [String: Any] = [
                "id": id,
                "phase": phase,
                "status": status,
                "round": 1,
                "labelKey": "insights.coach.activity." + phase,
                "label": label
            ]
            if let title { entry["title"] = title }
            return frame(["type": "activity", "activity": entry])
        }

        private static var streamParts: (String, String) {
            let lang = language
            let head = activity(
                "a1",
                "thinking",
                "done",
                lang.pick(de: "Denkt nach…", en: "Thinking…", nl: "Nadenken…"),
                title: lang.pick(
                    de: "Schlaf der letzten Woche ansehen",
                    en: "Look at last week's sleep",
                    nl: "Slaap van de afgelopen week bekijken"
                )
            )
                + activity(
                    "a2", "fetch", "running",
                    lang.pick(de: "Holt Schlaf, 7 Tage…", en: "Fetching sleep, 7 days…", nl: "Slaap ophalen, 7 dagen…")
                )
            let answer = lang.pick(
                de: "Deine Nächte waren in dieser Woche im Mittel 6 Stunden 40 Minuten lang, etwas kürzer als in den Wochen davor. Am Wochenende hast du länger geschlafen.",
                en: "Your nights this week averaged 6 hours 40 minutes, a little shorter than the weeks before. At the weekend you slept longer.",
                nl: "Je nachten duurden deze week gemiddeld 6 uur en 40 minuten, iets korter dan de weken ervoor. In het weekend sliep je langer."
            )
            var tail = activity(
                "a2", "fetch", "done",
                lang.pick(de: "7 Werte aus 1 Bereich", en: "7 readings from 1 area", nl: "7 metingen uit 1 gebied")
            )
                + activity(
                    "a3", "answer", "running",
                    lang.pick(de: "Schreibt die Antwort…", en: "Writing the answer…", nl: "Antwoord schrijven…")
                )
            for word in answer.split(separator: " ") {
                tail += frame(["type": "token", "token": String(word) + " "])
            }
            tail += frame(["type": "planProposal", "proposal": [
                "planId": "pl-hermetic", "metric": "sleep", "reviewInDays": 14,
                "ifCue": lang.pick(de: "es 22 Uhr ist", en: "it is 10 pm", nl: "het 22.00 uur is"),
                "thenAction": lang.pick(de: "lege ich das Handy weg", en: "I put my phone away", nl: "leg ik mijn telefoon weg")
            ]])
            tail += frame(["type": "done", "conversationId": "c-hermetic", "messageId": "m-hermetic"])
            return (head, tail)
        }

        private static var trailJSON: String {
            let lang = language
            let entries: [[String: Any]] = [
                [
                    "id": "a1",
                    "title": lang.pick(
                        de: "Schlaf der letzten Woche ansehen",
                        en: "Look at last week's sleep",
                        nl: "Slaap van de afgelopen week bekijken"
                    ),
                    "text": lang.pick(
                        de: "Die Frage betrifft die Schlafdauer, also zuerst die letzten sieben Nächte.",
                        en: "The question is about sleep length, so the last seven nights first.",
                        nl: "De vraag gaat over slaapduur, dus eerst de afgelopen zeven nachten."
                    )
                ],
                ["id": "a2"],
                ["id": "a3"]
            ]
            let object: [String: Any] = [
                "data": [
                    "trail": ["entries": entries, "recalled": [
                        lang.pick(de: "Läuft lieber morgens", en: "Prefers running in the morning", nl: "Loopt liever 's ochtends")
                    ]],
                    "ai": ["available": true]
                ],
                "error": NSNull()
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }
#endif
