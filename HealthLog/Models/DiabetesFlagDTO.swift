import Foundation

/// **v1.18.6 — per-user diabetes opt-in flag.**
///
/// Wire shape for `GET`/`PATCH /api/auth/me/diabetes` (OpenAPI
/// `DiabetesFlagOutput` / `DiabetesFlag`). A user-declared preference only —
/// NEVER inferred from a reading, never a diagnosis. When `true`, the server's
/// glucose target resolver applies the tighter ADA glycemic GOAL bands
/// (fasting 80–130, postprandial < 180) instead of the general non-diabetic
/// bands.
///
/// **Render-only / server-first.** iOS surfaces the switch and re-reads the
/// resolved flag; the ADA bands are applied SERVER-SIDE to glucose status —
/// the client never recomputes reference ranges from this flag.
public struct DiabetesFlagDTO: Codable, Sendable, Equatable {
    public let hasDiabetes: Bool

    public init(hasDiabetes: Bool) {
        self.hasDiabetes = hasDiabetes
    }
}
