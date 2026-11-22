#if DEBUG
    import Foundation

    /// **iOS 1.7 labs, cycle and seizure surfaces, for the picture sweep.**
    ///
    /// Under `-uitest-wo17` the fixture server speaks the 1.48 contract on
    /// top of whatever world the run boots: the `seizures` module is on and
    /// `/api/seizures` holds a small diary (two types, two seizures, one
    /// cluster); the cycle calendar carries a projection of three cycles; the
    /// biomarker catalog names two panels of the person's own; the labs list
    /// layout groups by category with only flagged groups open; the timeline
    /// gets a seizure lane and a hidden symptom; the account acts as the
    /// guardian of a managed profile, so the vault shows the profile's own
    /// reading switch. The first type's alert is five seconds, so the sweep
    /// photographs the plan panel without waiting minutes. Everything is
    /// invented; no value of any real person appears here.
    enum WO17Fixtures {
        static let argument = "-uitest-wo17"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(
            for request: URLRequest,
            base: () -> (status: Int, body: Data)
        ) -> (status: Int, body: Data)? {
            guard isActive, let url = request.url else { return nil }
            let method = request.httpMethod ?? "GET"
            switch (method, url.path) {
            case ("GET", "/api/auth/me"):
                return (200, patchedAuthMe(base().body))
            case ("GET", "/api/seizures"):
                return envelope(diary)
            case ("POST", "/api/seizures/events"):
                return (201, Data(#"{"data":\#(event(id: "wo17-new", type: "wo17-t1", minutesAgo: 0, duration: 7)),"error":null}"#.utf8))
            case let (_, path) where path.hasPrefix("/api/seizures"):
                return envelope("{}")
            case ("GET", "/api/cycle/calendar"):
                return (200, patchData(base().body) { data in
                    data["projection"] = projection
                    data["projectionState"] = "OK"
                })
            case ("GET", "/api/biomarkers"):
                return (200, patchData(base().body) { data in
                    data["customPanels"] = ["Praxis Dr. Sommer", "Sportmedizin", "Coagulation clinic", "Gerinnungsambulanz"]
                })
            case ("GET", "/api/settings/module-list-layout"):
                return envelope(#"{"version":1,"lists":{"labs":{"view":"list","groupBy":"category","groupsOpen":"flagged","saved":true}}}"#)
            case ("GET", "/api/record-settings/documents"):
                return envelope(#"{"recordId":"hermetic-user","family":"documents","settings":{"autoAiRead":false}}"#)
            case ("PATCH", "/api/record-settings/documents"):
                return envelope(#"{"recordId":"hermetic-user","family":"documents","settings":{"autoAiRead":true}}"#)
            case ("GET", "/api/timeline"):
                return (200, patchData(base().body, apply: patchTimeline))
            default:
                return nil
            }
        }

        // MARK: - Envelope helpers

        private static func envelope(_ data: String) -> (status: Int, body: Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        /// Applies `apply` to the envelope's `data` (or the bare object).
        private static func patchData(_ body: Data, apply: (inout [String: Any]) -> Void) -> Data {
            guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
            if var data = object["data"] as? [String: Any] {
                apply(&data)
                object["data"] = data
            } else {
                apply(&object)
            }
            return (try? JSONSerialization.data(withJSONObject: object)) ?? body
        }

        private static func patchedAuthMe(_ body: Data) -> Data {
            patchData(body) { me in
                var modules = me["modules"] as? [String: Any] ?? [:]
                modules["seizures"] = true
                modules["timeline"] = true
                me["modules"] = modules
                let guardian: [String: Any] = [
                    "accountId": "wo17-managed", "username": "sam", "displayName": "Sam",
                    "level": "manage", "recordKind": "managed", "sections": NSNull(), "canWrite": true
                ]
                me["accountAccess"] = [
                    "accounts": [guardian], "active": guardian, "recordKind": "managed", "canSwitch": true
                ]
            }
        }

        // MARK: - Timeline

        private static func patchTimeline(_ data: inout [String: Any]) {
            var lanes = data["lanes"] as? [[String: Any]] ?? []
            let day = { (offset: Int) in ProfileDay.key(CycleCalendarWindow.todayKey(), addingDays: -offset) }
            lanes.append(["key": "seizures", "items": [
                [
                    "id": "seizure-day:a",
                    "kind": "seizureDay",
                    "start": day(3),
                    "end": NSNull(),
                    "open": false,
                    "label": "Der Große",
                    "sub": "1",
                    "href": "/seizures"
                ],
                [
                    "id": "seizure-day:b",
                    "kind": "seizureDay",
                    "start": day(11),
                    "end": NSNull(),
                    "open": false,
                    "label": "Absence",
                    "sub": "6",
                    "href": "/seizures"
                ]
            ]])
            data["lanes"] = lanes
            var symptoms = data["availableSymptoms"] as? [[String: Any]] ?? []
            symptoms.append([
                "key": "symptom:sd_dizzy",
                "definitionId": "sd_dizzy",
                "label": "Schwindel",
                "icon": NSNull(),
                "isActive": false
            ])
            data["availableSymptoms"] = symptoms
        }

        // MARK: - Cycle

        private static var projection: [[String: Any]] {
            let day = { (offset: Int) in ProfileDay.key(CycleCalendarWindow.todayKey(), addingDays: offset) }
            return [
                ["k": 1, "start": day(19), "periodLength": 5, "bandStart": day(17), "bandEnd": day(21)],
                ["k": 2, "start": day(47), "periodLength": 5, "bandStart": day(43), "bandEnd": day(51)],
                ["k": 3, "start": day(75), "periodLength": 5, "bandStart": day(69), "bandEnd": day(81)]
            ]
        }

        // MARK: - Seizures

        private static func instant(minutesAgo: Int) -> String {
            SeizureDateFormat.wire(Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)))
        }

        private static func event(id: String, type: String, minutesAgo: Int, duration: Int?, count: Int = 1) -> String {
            let onset = instant(minutesAgo: minutesAgo)
            let durationJSON = duration.map(String.init) ?? "null"
            let source = duration == nil ? "UNKNOWN" : "TIMED"
            return """
            {"id":"\(id)","typeProfileId":"\(type)","onsetAt":"\(onset)","onsetPrecision":"EXACT",\
            "durationSec":\(durationJSON),"durationSource":"\(source)","count":\(count),"certainty":"CONFIRMED",\
            "sleepState":"AWAKE","semiology":["STARING"],"triggers":["SLEEP_DEPRIVATION"],"postictal":[],"injuries":[],\
            "emergency":"NONE","witnessed":true,"witnessRole":"PARENT","loggedBy":"owner","loggedByViewer":true,\
            "source":"MANUAL","note":null,"rescueDoses":[],"flags":{"overT1":null,"prolonged":null},\
            "createdAt":"\(onset)","updatedAt":"\(onset)"}
            """
        }

        private static var diary: String {
            let tonicOnset = instant(minutesAgo: 3 * 24 * 60 + 90)
            let tonic = """
            {"id":"wo17-e1","typeProfileId":"wo17-t1","effectiveIlaeType":"GENERALIZED_TC","onsetAt":"\(tonicOnset)",\
            "onsetPrecision":"EXACT","durationSec":250,"durationSource":"TIMED","count":1,"certainty":"CONFIRMED",\
            "sleepState":"ASLEEP","semiology":["TONIC","CLONIC"],"triggers":["MISSED_DOSE"],"postictal":["SLEEP","CONFUSION"],\
            "injuries":["TONGUE_BITE"],"emergency":"EMS_CALLED","witnessed":true,"witnessRole":"PARENT","loggedBy":"owner",\
            "loggedByViewer":true,"source":"MANUAL","note":"Nachts, danach lange geschlafen.",\
            "flags":{"overT1":false,"prolonged":true},\
            "rescueDoses":[{"id":"wo17-d1","eventId":"wo17-e1","medicationId":"wo17-m1","medicationName":"Buccolam",\
            "doseAmount":7.5,"doseUnit":"mg","route":"BUCCAL","givenAt":"\(tonicOnset)","givenBy":"PARENT",\
            "effect":"STOPPED","seizureEndedAt":null,"intakeEventId":"wo17-i1"}],\
            "createdAt":"\(tonicOnset)","updatedAt":"\(tonicOnset)"}
            """
            let absences = event(id: "wo17-e2", type: "wo17-t2", minutesAgo: 11 * 24 * 60, duration: nil, count: 6)
            let clusterStart = instant(minutesAgo: 11 * 24 * 60)
            let since = instant(minutesAgo: 90 * 24 * 60)
            return """
            {"types":[\
            {"id":"wo17-t1","label":"Der Große","ilaeType":"GENERALIZED_TC","usualDurationSec":90,\
            "rescuePlan":"Buccolam 7,5 mg in die Wangentasche geben. Seitenlage, nichts in den Mund. Notruf, wenn der Anfall nach der Gabe nicht aufhört.",\
            "rescueMedicationId":"wo17-m1","rescueMedicationName":"Buccolam","rescueDoseAmount":7.5,"rescueDoseUnit":"mg",\
            "rescueRoute":"BUCCAL","sortOrder":0,"archived":false,"alert":{"seconds":5,"source":"usualPlusTwo"}},\
            {"id":"wo17-t2","label":"Absence","ilaeType":"ABSENCE_TYPICAL","usualDurationSec":null,"rescuePlan":null,\
            "rescueMedicationId":null,"rescueMedicationName":null,"rescueDoseAmount":null,"rescueDoseUnit":null,\
            "rescueRoute":null,"sortOrder":1,"archived":false,"alert":{"seconds":600,"source":"t1"}}],\
            "settings":{"rule":{"count":2,"windowHours":24},"niceRule":{"count":3,"windowHours":24}},\
            "events":[\(tonic),\(absences)],\
            "summary":{"from":"\(since)","to":"\(instant(minutesAgo: 0))","days":90,"seizures":7,"suspected":0,\
            "seizureDays":2,"seizureFreeDays":88,"per28Days":2.2,"convulsive":1,"fromSleep":1,"rescueDoses":1,\
            "emergencies":{"emsCalled":1,"edVisits":0,"admissions":0},\
            "streak":{"daysSinceLast":3,"lastAt":"\(tonicOnset)","longestFreeDays":61},\
            "clusters":[{"startAt":"\(clusterStart)","endAt":"\(clusterStart)","seizureCount":6,"eventIds":["wo17-e2"]}],\
            "niceClusterCount":1},"truncated":false}
            """
        }
    }
#endif
