#if DEBUG
    import Foundation

    /// **SYMPTOM (1.5.0, #144) — symptoms on an illness episode.**
    ///
    /// Under `-uitest-symptom` (with `-uitest-area-meds`, whose illness table
    /// serves the episodes) the fixture server holds four symptom definitions
    /// and five occurrences: three filed against the open Bronchitis, one
    /// inside the Bronchitis days but filed against nothing (it must not
    /// show, server #1237), and one filed against the resolved Influenza.
    /// `GET /api/symptoms/events` answers by `episodeId` like a v1.43.4
    /// server. Everything is invented; no value of any real person appears
    /// here. `nil` for every other route.
    enum SymptomFixtures {
        static let argument = "-uitest-symptom"

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
                let filed = events.filter { $0.episode == episodeID }.map(\.json)
                return envelope(#"{"events":[\#(filed.joined(separator: ","))],"limit":500,"hasMore":false}"#)
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func definition(_ id: String, _ label: String, _ order: Int, active: Bool = true) -> String {
            #"{"id":"\#(id)","label":"\#(label)","icon":null,"sortOrder":\#(order),"isActive":\#(active),"#
                + #""recent":{"count30d":0,"maxIntensity30d":null,"lastOccurredAt":null}}"#
        }

        private static let definitions = [
            definition("sym-cough", "Husten", 0),
            definition("sym-throat", "Halsschmerzen", 1),
            definition("sym-headache", "Kopfschmerzen", 2),
            definition("sym-fatigue", "Erschöpfung", 3, active: false)
        ]

        private struct Event {
            let id: String
            let definition: String
            let daysAgo: Int
            let hour: Int
            let intensity: Int
            let episode: String?

            var json: String {
                let link = episode.map { "\"\($0)\"" } ?? "null"
                let at = SymptomFixtures.stamp(daysAgo: daysAgo, hour: hour)
                return #"{"id":"\#(id)","definitionId":"\#(definition)","occurredAt":"\#(at)","intensity":\#(intensity),"#
                    + #""note":null,"episodeId":\#(link),"createdAt":"\#(at)","updatedAt":"\#(at)"}"#
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
            let calendar = Calendar(identifier: .gregorian)
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)) ?? .now
            let date = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
    }
#endif
