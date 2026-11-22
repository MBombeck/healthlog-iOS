#if DEBUG
    import Foundation

    /// **Symptoms on an illness episode.**
    ///
    /// Under `-uitest-symptom` (with `-uitest-area-meds`, whose illness table
    /// serves the episodes) the fixture server holds four symptom definitions
    /// and five occurrences: three filed against the open Bronchitis, one
    /// inside the Bronchitis days but filed against nothing (it must not
    /// show, server #1237), and one filed against the resolved Influenza.
    /// `GET /api/symptoms/events` answers by `episodeId` like a v1.43.4
    /// server. Everything is invented; no value of any real person appears
    /// here. `nil` for every other route.
    ///
    /// #191 — with `-uitest-dose-offset` as well, the list carries each
    /// occurrence's `doseOffset` and `GET /api/version` names the
    /// `day.dose-offset` key, like a 1.49.0 server: the newest cough 2 h 10 min
    /// after Metformin, the sore throat 40 min before Naproxen, the fatigue
    /// at the time of Metformin.
    enum SymptomFixtures {
        static let argument = "-uitest-symptom"
        static let doseOffsetArgument = "-uitest-dose-offset"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard isActive, method == "GET" else { return nil }
            switch path {
            case "/api/symptoms/definitions":
                return envelope(#"{"definitions":[\#(definitions.joined(separator: ","))],"limit":8}"#)
            case "/api/symptoms/events":
                let episodeID = query.first { $0.name == "episodeId" }?.value
                let filed = events.filter { $0.episode == episodeID }.map { $0.json(offset: offsets[$0.id]) }
                return envelope(#"{"events":[\#(filed.joined(separator: ","))],"limit":500,"hasMore":false}"#)
            case "/api/version" where withOffsets:
                return envelope(#"{"version":"1.49.0","features":["day.dose-offset"]}"#)
            default:
                return nil
            }
        }

        private static var withOffsets: Bool {
            ProcessInfo.processInfo.arguments.contains(doseOffsetArgument)
        }

        /// The occurrences' `doseOffset`, only under `-uitest-dose-offset`.
        private static var offsets: [String: String] {
            guard withOffsets else { return [:] }
            return [
                "sym-e1": #"{"intakeId":"dose-1","title":"Metformin","minutes":130}"#,
                "sym-e2": #"{"intakeId":"dose-2","title":"Naproxen","minutes":-40}"#,
                "sym-e3": #"{"intakeId":"dose-3","title":"Metformin","minutes":0}"#
            ]
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        /// #191 QoL — `uses` is the 30-day count, so the chips stand by use:
        /// the headache (three times) ahead of the cough (twice), the sore
        /// throat in the server's place after them.
        private static func definition(_ id: String, _ label: String, _ order: Int, uses: Int = 0, active: Bool = true) -> String {
            let last = uses > 0 ? "\"\(stamp(daysAgo: 2, hour: 11))\"" : "null"
            return #"{"id":"\#(id)","label":"\#(label)","icon":null,"sortOrder":\#(order),"isActive":\#(active),"#
                + #""recent":{"count30d":\#(uses),"maxIntensity30d":null,"lastOccurredAt":\#(last)}}"#
        }

        private static let definitions = [
            definition("sym-cough", "Husten", 0, uses: 2),
            definition("sym-throat", "Halsschmerzen", 1),
            definition("sym-headache", "Kopfschmerzen", 2, uses: 3),
            definition("sym-fatigue", "Erschöpfung", 3, active: false)
        ]

        private struct Event {
            let id: String
            let definition: String
            let daysAgo: Int
            let hour: Int
            let intensity: Int
            let episode: String?

            func json(offset: String?) -> String {
                let link = episode.map { "\"\($0)\"" } ?? "null"
                let at = SymptomFixtures.stamp(daysAgo: daysAgo, hour: hour)
                let doseOffset = offset.map { #","doseOffset":\#($0)"# } ?? ""
                return #"{"id":"\#(id)","definitionId":"\#(definition)","occurredAt":"\#(at)","intensity":\#(intensity),"#
                    + #""note":null,"episodeId":\#(link),"createdAt":"\#(at)","updatedAt":"\#(at)"\#(doseOffset)}"#
            }
        }

        private static let events = [
            Event(id: "sym-e1", definition: "sym-cough", daysAgo: 1, hour: 9, intensity: 4, episode: bronchitis),
            Event(id: "sym-e2", definition: "sym-throat", daysAgo: 2, hour: 20, intensity: 6, episode: bronchitis),
            Event(id: "sym-e3", definition: "sym-fatigue", daysAgo: 3, hour: 14, intensity: 7, episode: bronchitis),
            Event(id: "sym-e4", definition: "sym-headache", daysAgo: 2, hour: 11, intensity: 5, episode: nil),
            Event(id: "sym-e5", definition: "sym-cough", daysAgo: 40, hour: 8, intensity: 8, episode: influenza)
        ]

        private static let bronchitis = AreaIllnessFixtures.bronchitisID
        private static let influenza = AreaIllnessFixtures.influenzaID

        fileprivate static func stamp(daysAgo: Int, hour: Int) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date(daysAgo: daysAgo, hour: hour))
        }

        private static func date(daysAgo: Int, hour: Int) -> Date {
            let calendar = Calendar(identifier: .gregorian)
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)) ?? .now
            return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
        }
    }
#endif
