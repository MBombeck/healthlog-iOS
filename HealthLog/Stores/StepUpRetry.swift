import Foundation
import Observation

/// R2 / #115 A3 — "ask for proof and retry", the one answer to a proof-family
/// refusal on a record action.
///
/// Server v1.39.3 gates the actions that hand the record (or a standing
/// credential to it) to somebody behind a fresh proof: the whole-record export
/// (`GET /api/export?type=all`), the encrypted export on an account with a
/// second factor, and — once a build like this one is the minimum — clinician
/// share links and MCP connector tokens. On a Bearer token the proof is a
/// single-use step-up elevation in `X-Step-Up`, minted at
/// `POST /api/auth/step-up`; without one the server answers
/// `401 auth.stepup.required` (the browser's `auth.reproof.*` codes mean the
/// same). `APIClient` keeps that 401 out of the refresh bridge
/// (``SecurityStepUp/isProofRefusal(body:)``); this type is what a store does
/// with it.
///
/// **Reactive on purpose.** The elevation is asked for only when the server
/// asks for it. Minting up front for every share link would spend the
/// per-account step-up budget (five per 15 minutes, shared with the web's
/// confirmation dialogs since v1.39.3) on routes that today still take the
/// token alone, and would put a password prompt in front of a person whose
/// server does not want one.
///
/// Flow: the store's action fails with a proof-family code →
/// ``requestIfProofRefusal(_:)`` raises ``isRequested`` → the screen presents
/// the step-up sheet (`.stepUpConfirmation`) → the minted elevation comes back
/// through ``supply(_:)`` → the screen re-runs the action, which takes the
/// elevation with ``take()`` exactly once.
@MainActor
@Observable
public final class StepUpRetry {
    /// The server asked for proof; the screen shows the step-up sheet.
    public private(set) var isRequested = false
    /// The minted, not yet used elevation. Never logged, never persisted, and
    /// gone after one ``take()``.
    @ObservationIgnored private var elevation: String?
    /// When ``supply(_:)`` received the elevation.
    @ObservationIgnored private var suppliedAt: Date?
    @ObservationIgnored private let now: () -> Date

    /// The oldest elevation ``take()`` still hands out.
    public nonisolated static let maximumAge: TimeInterval = 4 * 60

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Raises the request when `error` is a proof-family refusal and says
    /// whether it did. Drops any held elevation: the server refused it.
    @discardableResult
    public func requestIfProofRefusal(_ error: Error) -> Bool {
        guard SecurityStepUp.asksForProof(error) else { return false }
        elevation = nil
        isRequested = true
        return true
    }

    /// SEC — asks for proof before the action is sent at all. Drops any held
    /// elevation, so the proof that follows is the one the action carries.
    public func require() {
        elevation = nil
        suppliedAt = nil
        isRequested = true
    }

    /// The step-up sheet hands the minted elevation over.
    public func supply(_ token: String) {
        elevation = token
        suppliedAt = now()
        isRequested = false
    }

    /// The person closed the sheet without confirming.
    public func cancel() {
        elevation = nil
        suppliedAt = nil
        isRequested = false
    }

    /// The next attempt's elevation, at most once, and only while it is
    /// younger than ``maximumAge``.
    public func take() -> String? {
        defer {
            elevation = nil
            suppliedAt = nil
        }
        guard let suppliedAt, now().timeIntervalSince(suppliedAt) < Self.maximumAge else { return nil }
        return elevation
    }

    /// The sentence a card shows while the sheet asks for proof (and after it
    /// was closed without one).
    public nonisolated static var requiredMessage: String {
        String(localized: "stepUp.record.required")
    }
}
