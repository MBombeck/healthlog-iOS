import Foundation

/// **W-COACH-CADENCE (#30) — one proactive coach cadence suggestion.**
///
/// The coach surfaces a cadence suggestion **inline during a chat turn** as a
/// discrete SSE `suggestion` frame (see
/// ``CoachServerService/CoachReminderSuggestion``). There is NO proactive
/// `GET /api/coach/reminder-suggestions` catalogue on the server — the inline
/// frame is the only source. This value model is the render-surface twin the
/// proactive Insights card consumes: ``CoachConversationStore`` mints one from
/// the decoded inline frame and routes it into ``CoachCadenceSuggestionsStore``
/// so the same suggestion also appears as a calm accept/dismiss card near the
/// coach surface (not only mid-chat).
///
/// The app renders each row as an accept / dismiss card and POSTs only the
/// `cadenceId` + an action back (`POST /api/coach/reminder-suggestions`) — it can
/// never widen a cadence (the closed cadence catalogue + frequency-capping live
/// server-side).
///
/// **No `rationale`.** The inline `suggestion` frame carries only
/// `{ cadenceId, measurementType, label }` — there is no free-text rationale on
/// the wire, so this model intentionally omits one. `label` is an i18n key the
/// client resolves (with a generic fallback for an unknown key).
public struct CoachCadenceSuggestion: Sendable, Identifiable, Equatable {
    /// Stable row id. Keys on `cadenceId` (the action route keys on `cadenceId`,
    /// so this is always resolvable).
    public let id: String
    /// The closed-catalogue cadence id (e.g. `bp_7_2_2`). The ONLY identifier the
    /// client echoes back on an accept / dismiss / stop action.
    public let cadenceId: String
    /// Target metric (`UPPER_SNAKE`, e.g. `WEIGHT`, `BLOOD_PRESSURE_SYS`). `nil`
    /// for a free-text cadence. Kept as `String?` — never a closed enum.
    public let measurementType: String?
    /// i18n key for the cadence label the client resolves (with a generic
    /// fallback for an unknown key — see the card). NOT raw prose.
    public let label: String

    public init(
        id: String,
        cadenceId: String,
        measurementType: String?,
        label: String
    ) {
        self.id = id
        self.cadenceId = cadenceId
        self.measurementType = measurementType
        self.label = label
    }
}
