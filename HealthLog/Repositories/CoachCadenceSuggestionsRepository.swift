import Foundation

/// **W-COACH-CADENCE (#30) — proactive coach cadence-suggestion action wire.**
///
/// Thin wrapper over the **action** leg of the proactive coach cadence route:
///
/// - `POST /api/coach/reminder-suggestions { cadenceId, action }` → act on one.
///   `accept` creates the corresponding `MeasurementReminder` (origin COACH)
///   **server-side** and consumes the suggestion; `dismiss` hides it; `stop`
///   tells the coach to stop proposing this cadence.
///
/// There is **no `GET /api/coach/reminder-suggestions`** on the server — the
/// route exports only the POST. A proactive suggestion reaches the client
/// **inline** during a coach chat turn (a discrete SSE `suggestion` frame —
/// see ``CoachServerService/CoachReminderSuggestion``), which
/// ``CoachConversationStore`` routes into ``CoachCadenceSuggestionsStore``. This
/// repository therefore carries only the action POST.
///
/// **Client never widens a cadence.** The action POST carries ONLY `cadenceId` +
/// the action verb — the closed cadence catalogue, the reminder draft, and the
/// frequency-cap all live server-side. On `accept` the new reminder surfaces in
/// the native reminders list (Settings → Notifications → Manage reminders); the
/// store refreshes that list rather than fabricating a row locally.
public actor CoachCadenceSuggestionsRepository {
    /// The one-tap action on a proactive cadence suggestion.
    public enum Action: String, Sendable, Equatable {
        case accept
        case dismiss
        case stop
    }

    private let api: APIClientProtocol
    private let encoder: JSONEncoder

    public init(api: APIClientProtocol, encoder: JSONEncoder = .hlDefault) {
        self.api = api
        self.encoder = encoder
    }

    private static let basePath = "/api/coach/reminder-suggestions"

    /// `POST /api/coach/reminder-suggestions { cadenceId, action }` — act on one
    /// suggestion. The client sends only the id + action (never cadence
    /// parameters). On `accept` the server creates the reminder.
    public func act(cadenceId: String, action: Action) async throws {
        let req: APIRequest<ActionAck> = try .post(
            Self.basePath,
            body: ActionBody(cadenceId: cadenceId, action: action.rawValue),
            encoder: encoder
        )
        _ = try await api.send(req)
    }

    /// Request body for the action POST. Self-contained (not the service-file
    /// twin) so this repository stays plattform-free + compiles in the widget
    /// extension target (see project.yml allowlist doctrine).
    struct ActionBody: Encodable {
        let cadenceId: String
        let action: String
    }

    /// Tolerant `2xx { data: ... }` acknowledgement — the body is not read
    /// (accept creates the reminder server-side; the reminders list reflects it).
    /// Module-internal (not `private`) so the store test can stub the POST leg.
    struct ActionAck: Decodable {
        init() {}
        init(from _: Decoder) throws {}
    }
}
