import Foundation

/// One device of the account as the reminder rule sees it, reduced from a row of
/// `GET /api/auth/me/devices`.
public struct ReminderDevice: Sendable, Equatable {
    /// The server's `label`: the `model` the app registered (`UIDevice.model`),
    /// so "iPhone" for a phone and a Duo, "iPad" for a pad.
    public let label: String
    /// `lastSeenAt`: stamped by the server on every device registration.
    public let lastSeenAt: Date
    /// `isCurrent`: the row of the device that asked.
    public let isCurrent: Bool

    public init(label: String, lastSeenAt: Date, isCurrent: Bool = false) {
        self.label = label
        self.lastSeenAt = lastSeenAt
        self.isCurrent = isCurrent
    }
}

/// `GET /api/auth/me/devices`: the notification registrations of the account
/// (APNs and Web Push), one row per device. Read-only. The reminder rule uses it
/// to learn whether another iPhone is active; it is not a credential inventory
/// (see ``SessionsRepository``).
///
/// Wire shape (server `src/app/api/auth/me/devices/route.ts`, envelope
/// `{ data: { devices: [...] }, error: null }`):
/// `id`, `label`, `platform`, `appVersion`, `locale`, `channels`, `lastSeenAt`,
/// `createdAt`, `isCurrent`.
public actor DevicesRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func list() async throws -> [ReminderDevice] {
        let req: APIRequest<DeviceListResponse> = .get("/api/auth/me/devices")
        return try await api.send(req).devices.map(\.reminderDevice)
    }
}

struct DeviceListResponse: Decodable, Sendable, Equatable {
    let devices: [DeviceEntry]

    struct DeviceEntry: Decodable, Sendable, Equatable {
        let id: String
        let label: String
        let platform: String?
        let lastSeenAt: Date
        let isCurrent: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            platform = try c.decodeIfPresent(String.self, forKey: .platform)
            lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
            isCurrent = try c.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case id, label, platform, lastSeenAt, isCurrent
        }

        var reminderDevice: ReminderDevice {
            ReminderDevice(label: label, lastSeenAt: lastSeenAt, isCurrent: isCurrent)
        }
    }
}
