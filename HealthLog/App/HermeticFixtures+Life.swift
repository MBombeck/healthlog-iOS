#if DEBUG
    import Foundation

    /// **LIFE (1.5.0, #132) — the life circumstances, writable.**
    ///
    /// Under `-uitest-life` the fixture server says it has
    /// `features.lifeCircumstances` and keeps the answers in memory: a POST,
    /// PATCH or DELETE on `/api/anamnesis/facts` changes what the next
    /// `GET /api/anamnesis/life-circumstances` returns, so a UI test can save
    /// an answer, leave the screen and find it again. Everything is invented;
    /// no value of any real person appears here. `nil` for every other route,
    /// and for every route without the argument.
    enum LifeFixtures {
        static let argument = "-uitest-life"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        private struct Fact {
            let id: String
            let kind: String
            let value: Any
            let validFrom: String
        }

        private static let lock = NSLock()
        /// POLISH-C (C7): the one-word alcohol answer from before AUDIT-C,
        /// kept in the record and shown in the alcohol section.
        private nonisolated(unsafe) static var facts: [Fact] = [
            Fact(id: "life-legacy-alcohol", kind: "ALCOHOL_PATTERN", value: "WEEKLY", validFrom: "2025-03-01T12:00:00.000Z")
        ]
        private nonisolated(unsafe) static var aiSections: Set<String> = ["SMOKING_STATUS", "ACTIVITY", "WORK", "HABITS", "GOALS"]
        private nonisolated(unsafe) static var counter = 0

        static func response(for request: URLRequest) -> (status: Int, body: Data)? {
            guard isActive, let path = request.url?.path else { return nil }
            let method = request.httpMethod ?? "GET"
            return lock.withLock {
                route(path: path, method: method, body: body(of: request))
            }
        }

        private static func route(path: String, method: String, body: [String: Any]) -> (Int, Data)? {
            switch (method, path) {
            case ("GET", "/api/auth/me"):
                return ok(meJSON)
            case ("GET", "/api/anamnesis/life-circumstances"):
                return ok(payloadJSON())
            case ("GET", "/api/anamnesis/facts"):
                let current = ["SMOKING_STATUS", "ALCOHOL_PATTERN", "SHIFT_SCHEDULE"].map { kind in
                    #""\#(kind)":\#(facts.last(where: { $0.kind == kind }).map(revision) ?? "null")"#
                }.joined(separator: ",")
                return ok(#"{"current":{\#(current)},"history":[]}"#)
            case ("POST", "/api/anamnesis/facts"):
                guard let kind = body["kind"] as? String, let value = body["value"] else { return (422, Data()) }
                counter += 1
                let fact = Fact(id: "life-fact-\(counter)", kind: kind, value: value, validFrom: validFrom(body))
                facts.append(fact)
                return (201, envelope(revision(fact)))
            case ("PATCH", "/api/anamnesis/life-circumstances/ai-sections"):
                for (key, on) in (body["sections"] as? [String: Bool]) ?? [:] {
                    if on { aiSections.insert(key) } else { aiSections.remove(key) }
                }
                return ok(#"{"aiSections":{},"updatedAt":"2026-11-04T12:00:00.000Z"}"#)
            case ("POST", "/api/anamnesis/life-circumstances/confirm"):
                return ok(#"{"section":"tobacco","lastConfirmedAt":"2026-11-04T12:00:00.000Z"}"#)
            default:
                if let (status, json) = LifeAuditCFixtures.route(path: path, method: method, body: body) {
                    return (status, envelope(json))
                }
                return factRoute(path: path, method: method, body: body)
            }
        }

        private static func factRoute(path: String, method: String, body: [String: Any]) -> (Int, Data)? {
            let prefix = "/api/anamnesis/facts/"
            guard path.hasPrefix(prefix) else { return nil }
            let id = String(path.dropFirst(prefix.count))
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return (404, Data()) }
            let old = facts[index]
            switch method {
            case "PATCH":
                guard let value = body["value"] else { return (422, Data()) }
                counter += 1
                let fact = Fact(id: "life-fact-\(counter)", kind: old.kind, value: value, validFrom: validFrom(body))
                facts[index] = fact
                return ok(revision(fact))
            case "DELETE":
                facts.remove(at: index)
                return ok(#"{"id":"\#(id)","kind":"\#(old.kind)"}"#)
            default:
                return nil
            }
        }

        // MARK: - Payload

        private static func payloadJSON() -> String {
            let sections: [String: [String]] = [
                "tobacco": ["SMOKING_STATUS", "TOBACCO_DETAIL"], "alcohol": [], "activity": ["ACTIVITY_HABIT"],
                "work": ["SHIFT_SCHEDULE", "WORK_CONTEXT", "FREE_WEEKDAYS"], "habits": ["HABITS"], "goals": ["HEALTH_GOALS"]
            ]
            let ais = [
                "tobacco": "SMOKING_STATUS",
                "alcohol": "ALCOHOL_PATTERN",
                "activity": "ACTIVITY",
                "work": "WORK",
                "habits": "HABITS",
                "goals": "GOALS"
            ]
            let list = ["tobacco", "alcohol", "activity", "work", "habits", "goals"].map { key in
                let kinds = sections[key] ?? []
                let ai = ais[key] ?? ""
                let own = facts.filter { kinds.contains($0.kind) }.map(revision).joined(separator: ",")
                let confirmed = own.isEmpty ? "null" : #""2026-11-04T12:00:00.000Z""#
                return #"{"key":"\#(key)","aiSection":"\#(ai)","aiIncluded":\#(aiSections.contains(ai)),"lastConfirmedAt":\#(confirmed),"reviewDue":false,"facts":[\#(own)]}"#
            }.joined(separator: ",")
            return #"""
            {"sections":[\#(list)],"extraAiSections":{"SHIFT_SCHEDULE":\#(aiSections.contains("SHIFT_SCHEDULE"))},
             "derived":{"packYears":{"value":null,"status":"missing_inputs"},
               "activityMinutesPerWeek":{"value":null,"meetsWho150":null,"measuredStepsAvailable":false},
               "freeWeekdays":{"days":[6,7],"source":"default_weekend"},
               "screeningHints":[
                 {"id":"lung_ldct","status":"unknown","reasonKeys":["missing_birth_date","missing_smoking_history"],
                  "region":"US","sourceLabel":"USPSTF, Lung Cancer: Screening (2021) (United States)",
                  "sourceUrl":"https://www.uspreventiveservicestaskforce.org/uspstf/recommendation/lung-cancer-screening"},
                 {"id":"aaa_ultrasound","status":"unknown","reasonKeys":["missing_sex","missing_birth_date"],
                  "region":"US","sourceLabel":"USPSTF, Abdominal Aortic Aneurysm: Screening (2019) (United States)",
                  "sourceUrl":"https://www.uspreventiveservicestaskforce.org/uspstf/recommendation/abdominal-aortic-aneurysm-screening"}]},
             "auditC":\#(LifeAuditCFixtures.json()),
             "takeOver":[]}
            """#
        }

        private static func revision(_ fact: Fact) -> String {
            let value = (try? JSONSerialization.data(withJSONObject: fact.value, options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return #"{"id":"\#(fact.id)","kind":"\#(fact.kind)","value":\#(value),"unreadable":false,"#
                + #""validFrom":"\#(fact.validFrom)","validUntil":null,"provenance":"USER_REPORTED","#
                + #""createdAt":"2026-11-04T12:00:00.000Z"}"#
        }

        private static func validFrom(_ body: [String: Any]) -> String {
            (body["validFrom"] as? String).map { "\($0)T12:00:00.000Z" } ?? "2026-11-04T12:00:00.000Z"
        }

        // MARK: - Helpers

        private static func body(of request: URLRequest) -> [String: Any] {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&chunk, maxLength: chunk.count)
                    guard read > 0 else { break }
                    buffer.append(chunk, count: read)
                }
                data = buffer
            }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, envelope(json))
        }

        private static func envelope(_ json: String) -> Data {
            Data(#"{"data":\#(json),"error":null}"#.utf8)
        }

        private static let meJSON = """
        {
          "id": "hermetic-user",
          "email": "hermetic@uitest.local",
          "username": "hermetic",
          "displayName": "Hermetic Tester",
          "createdAt": "2024-01-01T00:00:00.000Z",
          "disclaimerAcknowledgedAt": "2024-01-01T00:00:00.000Z",
          "onboardingTourCompleted": true,
          "moodReminderEnabled": false,
          "modules": {},
          "moduleAccess": {},
          "features": { "lifeCircumstances": true }
        }
        """
    }
#endif
