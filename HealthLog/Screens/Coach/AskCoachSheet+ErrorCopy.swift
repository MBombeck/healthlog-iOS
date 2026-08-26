import SwiftUI

/// **AskCoach error-banner copy.**
///
/// Maps the view-layer ``LocalLLMError`` (and the typed causes it wraps) to
/// honest, per-case banner strings. Split out of
/// `AskCoachSheet+ServerFallback.swift` (C3 / b199) to keep that file under the
/// 600-line SwiftLint ceiling once the server-arm copy landed.
///
/// **C3 (b199 walkthrough) — the server arm now gets per-case copy too.**
/// Previously `runServerTurn` collapsed every failure into `.modelResponseFailed`
/// → the flat "Response failed. Please try again.", discarding the discriminating
/// cause (no provider/tokens, rate-limited, Coach turned off, offline, missing
/// consent receipt). The store now preserves the typed cause as `.serverFailed`
/// and ``serverErrorCopy(_:)`` maps it — mirroring the BYO arm's
/// ``byoErrorCopy(_:)``. Curated strings only: the raw server `code` is never
/// rendered.
extension AskCoachSheet {
    /// Maps a `LocalLLMError` to user-facing banner copy.
    func errorCopy(_ error: LocalLLMError) -> String {
        switch error {
        case .foundationModelsUnavailable:
            String(localized: "The Coach is currently unavailable.")
        case .modelResponseFailed:
            String(localized: "Response failed. Please try again.")
        case let .byoFailed(byoError):
            byoErrorCopy(byoError)
        case let .serverFailed(serverError):
            serverErrorCopy(serverError)
        }
    }

    /// **C3 (b199 walkthrough)** — honest, per-case copy for a SERVER-arm Coach
    /// failure, the sibling of ``byoErrorCopy(_:)``. Branches on the typed cause
    /// and maps it to an actionable message — never rendering the raw server
    /// `code` (same discipline as ``byoErrorCopy(_:)``).
    func serverErrorCopy(_ error: Error) -> String {
        switch error {
        case let serverError as CoachServerError:
            switch serverError {
            case let .provider(code):
                providerErrorCopy(code)
            case .decode, .emptyReply:
                String(localized: "Response failed. Please try again.")
            }
        case let hlError as HLError:
            hlErrorCopy(hlError)
        default:
            String(localized: "Response failed. Please try again.")
        }
    }

    /// Maps a server `coach.provider.*` / `coach.budget.*` error code to curated
    /// user copy. Never renders the raw code; an unknown code falls through to the
    /// generic retry.
    private func providerErrorCopy(_ code: String) -> String {
        switch code {
        case "coach.provider.none":
            String(
                localized: "No AI provider is available. Set one up in Settings → Assistant."
            )
        case "coach.provider.rate_limited":
            String(localized: "The Coach is busy right now. Try again shortly.")
        case "coach.budget.exceeded":
            // A360 M3 — the user hit their daily AI budget. Honest + actionable
            // (the budget resets) rather than the flat "Response failed".
            String(localized: "You've used today's AI budget. It resets tomorrow.")
        case "coach.provider.credential_expired":
            // A360 M3 — the server provider's credential expired (e.g. an OAuth
            // token lapsed). Point at where the user can fix it.
            String(localized: "Your AI provider needs reconnecting. Check Settings → Assistant.")
        default:
            String(localized: "The Coach couldn't answer right now. Try again shortly.")
        }
    }

    /// Maps transport / gating ``HLError`` cases surfaced by the server arm to
    /// honest copy (Coach turned off, offline, consent-required).
    private func hlErrorCopy(_ error: HLError) -> String {
        switch error {
        case .assistantDisabled:
            String(localized: "The Coach is turned off for your account.")
        case .rateLimited:
            // A360 M2 — a TRANSPORT 429 (per-user 20/min limit) surfaced as
            // `HLError.rateLimited`, distinct from the provider `error` frame
            // `coach.provider.rate_limited`. Honest "busy" copy with a retry hint.
            String(localized: "The Coach is busy right now. Try again in a moment.")
        case .offline,
             .network(.connectionLost),
             .network(.dnsFailure),
             .network(.timeout):
            String(
                localized: "You're offline — the server Coach needs a connection."
            )
        case let .server(status, _, _) where status == 403:
            // A 403 the API client did not map to `.assistantDisabled` is the
            // missing-consent-receipt failure-closed case — route to consent.
            String(
                localized: "The Coach needs your consent to use external AI. Grant it in Settings → Assistant."
            )
        default:
            String(localized: "Response failed. Please try again.")
        }
    }

    /// v0.13 W4 — honest, per-case copy for a BYO-key Coach failure. Maps the
    /// typed ``BYOLLMError`` to an actionable message (invalid key → point at
    /// Settings; unreachable / rate-limited / provider-down → plain retry copy).
    func byoErrorCopy(_ error: BYOLLMError) -> String {
        switch error {
        case .invalidKey, .invalidConfiguration:
            String(localized: "Your key was rejected. Check it in Settings → Assistant.")
        case .rateLimited:
            String(localized: "Your provider is rate-limiting requests. Try again shortly.")
        case .quotaExhausted:
            String(localized: "Your provider quota is used up. Check your account.")
        case .modelNotFound:
            String(localized: "That model is unknown to your provider. Pick another in Settings.")
        case .unreachable:
            String(localized: "Couldn't reach your provider. Check your connection.")
        case .providerUnavailable:
            String(localized: "Your provider is temporarily unavailable. Try again later.")
        case .safetyRefused:
            String(localized: "Your provider declined to answer this request.")
        case .badRequest, .decode:
            String(localized: "Response failed. Please try again.")
        }
    }
}
