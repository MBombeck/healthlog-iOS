import Foundation

/// `GET` / `PATCH /api/record-settings/documents` (server v1.48.0, #1403,
/// #182 A5): the managed profile's own automatic-reading switch. Only the
/// guardian acting on a managed profile reaches it; the answer names the
/// record (`{ recordId, family, settings }`). Turning it on mints the
/// profile's AI-extraction receipt on the server and may queue a bounded
/// catch-up over stored documents; the app only sends the switch.
public actor RecordSettingsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// `settings` of the documents family.
    public struct DocumentSettings: Codable, Sendable, Equatable {
        public let autoAiRead: Bool

        public init(autoAiRead: Bool) {
            self.autoAiRead = autoAiRead
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            autoAiRead = (try? c.decodeIfPresent(Bool.self, forKey: .autoAiRead)) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case autoAiRead
        }
    }

    struct Envelope: Decodable, Sendable {
        let recordId: String?
        let settings: DocumentSettings
    }

    public static let documentsPath = "/api/record-settings/documents"

    public func documentSettings() async throws -> DocumentSettings {
        let request: APIRequest<Envelope> = .get(Self.documentsPath)
        return try await api.send(request).settings
    }

    public func setAutoAiRead(_ isOn: Bool) async throws -> DocumentSettings {
        let request: APIRequest<Envelope> = try .patch(Self.documentsPath, body: DocumentSettings(autoAiRead: isOn))
        return try await api.send(request).settings
    }
}
