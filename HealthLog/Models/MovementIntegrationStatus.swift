import Foundation

/// **1.5 MOVE (#133)** — the `dawarich` entry of `GET /api/integrations/status`,
/// for its row in Settings › Integrations. Read for display only: whether it
/// is connected and its ``ConnectionHealth``. Every other provider in the
/// envelope is skipped here, an entry that does not decode is skipped rather
/// than failing the read, and a server that does not list `dawarich` (before
/// v1.43) yields `nil`, so the row does not appear.
struct DawarichIntegrationPayload: Decodable, Sendable {
    struct Entry: Decodable, Sendable, Equatable {
        let integration: String?
        let connected: Bool
        let health: ConnectionHealth?

        init(integration: String?, connected: Bool, health: ConnectionHealth?) {
            self.integration = integration
            self.connected = connected
            self.health = health
        }

        private enum CodingKeys: String, CodingKey {
            case integration, connected, health
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            integration = try? c.decodeIfPresent(String.self, forKey: .integration)
            connected = (try? c.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
            health = ConnectionHealth.tolerant(from: c, forKey: .health)
        }
    }

    let integrations: [Entry]

    private enum CodingKeys: String, CodingKey {
        case integrations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        integrations = (try? c.decodeIfPresent([Entry].self, forKey: .integrations)) ?? []
    }

    var dawarich: Entry? {
        integrations.first { $0.integration == "dawarich" }
    }
}
