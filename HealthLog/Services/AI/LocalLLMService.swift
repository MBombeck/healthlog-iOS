import Foundation
import Observation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// On-device chat service scaffolding for v0.5.7 G.1.
///
/// **Scope:** stand up the kill-card surface for the AskCoach hero by
/// exposing Apple FoundationModels' `SystemLanguageModel.default.availability`
/// behind a single `@Observable` reader, and run the real one-shot
/// `respond(_:)` call against `LanguageModelSession` on iOS 26+. The session
/// is hoisted to the service's lifetime (#14): created lazily on first
/// `prewarm()` / send, reused across turns so the model carries the
/// conversation context, dropped on `resetSession()` (conversation clear /
/// logout) and on availability flips, and rebuilt with a condensed transcript
/// when the context window overflows.
///
/// **Availability:** the public type compiles on iOS 18+ (the package
/// target deployment baseline) so call-sites do not need `#available`
/// guards. The actual FoundationModels-backed wiring is gated by
/// `@available(iOS 26.0, *)` per the v0.5.7 brief — `SystemLanguageModel`
/// only ships on iOS 26.0+ alongside Apple Intelligence. On iOS 18 / 25
/// the `availability` reader stays `.unsupported` so the AskCoach kill-card
/// renders the legacy "Coming Soon" panel.
///
/// **Why a @MainActor @Observable wrapper around a tri-state enum?**
/// `LanguageModelSession` is itself main-actor-isolated upstream, and the
/// AskCoach hero hosts the kill-card directly in the SwiftUI view tree —
/// the @Observable readback hop stays on the same actor SwiftUI is
/// already on, so `availability` reads cost a single property load
/// per body invocation with no actor-hopping.
@MainActor
@Observable
public final class LocalLLMService {
    /// On-device LLM availability, mapped from
    /// `SystemLanguageModel.default.availability` when running on iOS 26+.
    ///
    /// The cases mirror Apple's `SystemLanguageModel.Availability` so the
    /// AskCoach kill-card can branch on a single source of truth without
    /// importing FoundationModels everywhere. The `.unsupported` case
    /// captures the iOS 18 / 25 floor where FoundationModels is not
    /// linkable at all.
    public enum Availability: Sendable, Equatable {
        /// `SystemLanguageModel.Availability.available` — the model is
        /// downloaded, Apple Intelligence is enabled, and the device is
        /// eligible.
        case available
        /// Apple Intelligence is toggled OFF in Settings → Apple
        /// Intelligence & Siri. Kill-card surfaces a "turn on Apple
        /// Intelligence" deep link.
        case appleIntelligenceNotEnabled
        /// The on-device weights are still downloading or have not yet
        /// landed. Kill-card surfaces a "Modell wird vorbereitet" note +
        /// retries on `scenePhase == .active`.
        case modelNotReady
        /// The hardware is not Apple-Intelligence-eligible (pre-iPhone
        /// 15 Pro / non-M-series iPad). Kill-card surfaces a
        /// device-ineligible note + hides the AskCoach hero entirely.
        case deviceNotEligible
        /// FoundationModels is not importable in this build configuration
        /// (Mac Catalyst, watchOS, or pre-iOS-26 runtime). Identical UX
        /// to `.deviceNotEligible` from the kill-card's perspective.
        case unsupported
    }

    /// Backing storage for the availability reader. Surfaced as a computed
    /// `availability` so future call-sites can override it in tests by
    /// subclassing without re-running the FoundationModels probe.
    private var cachedAvailability: Availability

    /// **v0.12 W8-2 / #14 — hoisted `LanguageModelSession`.** Held across
    /// turns so the transcript context survives and we don't pay the
    /// cold-start instantiation on every send (the documented G.3↔G.5 seam,
    /// resolved via issue #14). Lazily created on first `prewarm()` /
    /// `respond` / `streamResponse` so init stays cheap on the iOS-18 floor
    /// (the type only exists on iOS 26+). `AnyObject` storage so the property
    /// can live on the iOS-18-baseline type; cast back to
    /// `LanguageModelSession` behind the `#available` gate.
    ///
    /// Lifecycle:
    /// - dropped via ``resetSession()`` on conversation-clear + logout
    ///   (`CoachConversationStore.reset()` / `clearOnLogout`),
    /// - dropped via ``applyAvailability(_:)`` whenever the model availability
    ///   actually changes (e.g. Apple Intelligence toggled mid-conversation),
    /// - rebuilt with a condensed transcript via
    ///   ``recoverFromContextOverflow(_:)`` when a turn throws
    ///   `exceededContextWindowSize`.
    private var hoistedSession: AnyObject?

    /// **#14 test seam** — `true` while a session object is parked on the
    /// store-lifetime slot. Lets unit tests assert the reuse + reset paths
    /// without FoundationModels being instantiable on the CI simulator.
    public var hasActiveSession: Bool {
        hoistedSession != nil
    }

    /// Returns the cached session box, creating one via `create` when none is
    /// parked. The iOS-26 `session()` accessor routes through this so the
    /// caching contract ("create once, reuse across turns" — #14) is
    /// unit-testable with a stub object on runtimes where
    /// `LanguageModelSession` cannot be constructed.
    func cachedSession(create: () -> AnyObject) -> AnyObject {
        if let existing = hoistedSession {
            return existing
        }
        let fresh = create()
        hoistedSession = fresh
        return fresh
    }

    /// **#14 — store-lifetime session reset.** Drops the hoisted session so
    /// the next turn starts a fresh `LanguageModelSession` with no carried
    /// transcript. Called by `CoachConversationStore.reset()` ("Neue
    /// Unterhaltung") and `clearOnLogout`, and internally on availability
    /// flips — a cleared conversation must never leak prior turns into the
    /// model context.
    public func resetSession() {
        hoistedSession = nil
    }

    /// **#14 — availability-change invalidation.** Mutates the published
    /// availability reader and drops the hoisted session when the value
    /// actually changed (e.g. Apple Intelligence toggled off → on between
    /// turns): a session created under the old availability state must not
    /// serve turns under the new one. Internal so the unit-test seam can
    /// drive deterministic flips without the live probe.
    func applyAvailability(_ new: Availability) {
        if new != cachedAvailability {
            resetSession()
        }
        cachedAvailability = new
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        private func session() -> LanguageModelSession {
            let box = cachedSession { LanguageModelSession() }
            if let typed = box as? LanguageModelSession {
                return typed
            }
            // A non-session object can only be parked via the unit-test seam —
            // never in production. Replace defensively rather than trap.
            let fresh = LanguageModelSession()
            hoistedSession = fresh
            return fresh
        }

        /// **#14 — context-window overflow recovery.** When `error` is
        /// `LanguageModelSession.GenerationError.exceededContextWindowSize`,
        /// replaces the hoisted session with a fresh one carrying a condensed
        /// transcript (Apple's documented pattern: keep the first entry — the
        /// instructions — plus the most recent entry, dropping the overflowing
        /// middle) and returns `true` so the caller retries the turn exactly
        /// once. Any other error returns `false` and leaves the session
        /// untouched.
        @available(iOS 26.0, *)
        public func recoverFromContextOverflow(_ error: Error) -> Bool {
            guard let generationError = error as? LanguageModelSession.GenerationError,
                  case .exceededContextWindowSize = generationError else
            {
                return false
            }
            if let previous = hoistedSession as? LanguageModelSession {
                hoistedSession = Self.condensedSession(from: previous)
            } else {
                resetSession()
            }
            return true
        }

        /// Builds the post-overflow replacement session: first transcript
        /// entry (the instructions) + the latest entry, so the new session
        /// keeps the persona and the immediate context without the
        /// overflowing middle of the conversation.
        @available(iOS 26.0, *)
        private static func condensedSession(from previous: LanguageModelSession) -> LanguageModelSession {
            let entries = previous.transcript
            var condensed: [Transcript.Entry] = []
            if let first = entries.first {
                condensed.append(first)
                if entries.count > 1, let last = entries.last {
                    condensed.append(last)
                }
            }
            return LanguageModelSession(transcript: Transcript(entries: condensed))
        }
    #endif

    /// **v0.12 W8-2 — pre-warm hook.** Call when the Coach sheet is about to
    /// appear (`AskCoachSheet.onAppear`) so the model is loaded by the time the
    /// user submits the first turn, killing the visible cold-start spinner.
    /// Guarded internally on `availability == .available`; a no-op on every
    /// other runtime (pre-26, AI off, model downloading, device ineligible) so
    /// call-sites can fire it unconditionally on appear.
    public func prewarm() {
        #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else { return }
            guard cachedAvailability == .available else { return }
            session().prewarm()
        #endif
    }

    public init() {
        cachedAvailability = Self.probeAvailability()
    }

    /// **Test seam (v0.11 marathon, AI-1).** Constructs the service with a
    /// pinned `availability` instead of probing FoundationModels, so a suite
    /// can deterministically exercise the `isReady == true` (AI-capable device)
    /// branch on the CI simulator — where the real probe always resolves
    /// `.unsupported`. Not used in production (every app call-site uses the
    /// probing `init()`); the parameter label makes the intent explicit at the
    /// call site. No behaviour change for the production path.
    public init(forcedAvailability: Availability) {
        cachedAvailability = forcedAvailability
    }

    /// Current on-device availability snapshot. Resolved once at init and
    /// re-resolvable via `refresh()` — Apple's reader is synchronous +
    /// cheap, but G.3 may surface a "retry" CTA on the kill-card that
    /// calls `refresh()` after the user enables Apple Intelligence in
    /// Settings without re-launching.
    public var availability: Availability {
        cachedAvailability
    }

    /// Convenience flag for the AskCoach hero — `true` only when the
    /// FoundationModels path is ready to serve a request. Kept as a
    /// computed property so the @Observable change-tracker re-fires when
    /// `cachedAvailability` flips.
    public var isReady: Bool {
        cachedAvailability == .available
    }

    /// Re-probes `SystemLanguageModel.default.availability` and mutates
    /// the published `availability` reader. Cheap — Apple's accessor is a
    /// simple enum read, no I/O. Safe to call from any main-actor
    /// callback (e.g. `.onChange(of: scenePhase)`). **#14:** an actual
    /// availability change drops the hoisted session so the next turn
    /// re-creates it under the new model state.
    public func refresh() {
        applyAvailability(Self.probeAvailability())
    }

    /// Generates a one-shot structured `CoachInsight` for the given
    /// user prompt.
    ///
    /// **v0.5.7 G.2** wires the first real FoundationModels call against
    /// `LanguageModelSession.respond(to:generating:)` with the
    /// `@Generable CoachInsight` struct. **#14 (resolves the G.3↔G.5
    /// seam):** the session lives for the service's lifetime — created
    /// lazily, reused across turns so the chat transcript persists, reset on
    /// conversation-clear / logout / availability change, and rebuilt with a
    /// condensed transcript on context-window overflow.
    ///
    /// **v0.5.7 G.4 — on-device guarantee:** `LanguageModelSession`
    /// runs Apple's 3B-parameter Foundation Model entirely on-device
    /// (no network egress at the framework level — Apple's contract
    /// per `FoundationModels` documentation). The
    /// `PrivacyFirstPromptBuilder` (G.4) composes the prompt from
    /// local-only data and feeds it into this `respond(prompt:)`
    /// method; nothing in this code path opens a socket, writes to
    /// disk, or hands the prompt to any other framework. The privacy
    /// boundary is the `LanguageModelSession` constructor — every
    /// byte beyond that point stays on the device.
    ///
    /// **Availability contract:**
    /// - On iOS 18 / 25 (FoundationModels not linkable, `availability ==
    ///   .unsupported`): throws `.foundationModelsUnavailable` —
    ///   call-sites that ignore `isReady` get a loud failure instead of
    ///   silent stubbing.
    /// - On iOS 26+ with `availability != .available`
    ///   (Apple-Intelligence disabled, model still downloading, device
    ///   not eligible): throws `.foundationModelsUnavailable` for the
    ///   same fail-loud reason. The AskCoach hero is expected to gate
    ///   the call on `isReady` and surface the kill-card instead.
    /// - On iOS 26+ with `availability == .available`: instantiates a
    ///   `LanguageModelSession`, runs `respond(to:generating:)`, and
    ///   returns the structured `CoachInsight`. Generation errors
    ///   (safety refusal, context overflow, transient model errors) are
    ///   wrapped as `.modelResponseFailed(_:)` so the call-site can
    ///   inspect the underlying `LanguageModelSession.GenerationError`
    ///   without losing context.
    @available(iOS 26.0, *)
    public func respond(prompt: String) async throws -> CoachInsight {
        #if canImport(FoundationModels)
            // Re-probe the model availability synchronously — cheap (it's
            // an enum read) and protects against drift between the
            // service-init snapshot and the call-site (e.g. the user
            // enabled Apple Intelligence in Settings between sheet-open
            // and submit). The cached reader stays the source of truth
            // for `isReady` (which the AskCoach hero watches); #14 routes
            // the write through `applyAvailability` so an actual flip also
            // drops the hoisted session.
            applyAvailability(Self.probeAvailability())
            guard cachedAvailability == .available else {
                throw LocalLLMError.foundationModelsUnavailable
            }

            do {
                // **v0.12 W8-2 / #14** — use the hoisted session so transcript
                // context persists across turns and the cold-start is paid
                // once (or earlier via `prewarm()`), not per send.
                let response = try await session().respond(
                    to: prompt,
                    generating: CoachInsight.self
                )
                return response.content
            } catch {
                // **#14 — context overflow:** rebuild the session with a
                // condensed transcript and retry the turn exactly once so a
                // long conversation degrades gracefully instead of erroring.
                if recoverFromContextOverflow(error) {
                    do {
                        let retried = try await session().respond(
                            to: prompt,
                            generating: CoachInsight.self
                        )
                        return retried.content
                    } catch {
                        throw LocalLLMError.modelResponseFailed(error)
                    }
                }
                // Wrap the upstream error so the call-site (G.3
                // AskCoachStore) can surface a friendly retry CTA
                // without leaking `LanguageModelSession.GenerationError`
                // types into the UI layer. The original error is
                // preserved as the associated value for `HLLog` + the
                // future analytics breadcrumb.
                throw LocalLLMError.modelResponseFailed(error)
            }
        #else
            // FoundationModels is not linkable in this build
            // configuration (Mac Catalyst, pre-iOS-26 SDK). The
            // `@available(iOS 26.0, *)` annotation already prevents
            // call-sites from reaching this branch at runtime — the
            // throw is a defence-in-depth backstop so the compiler can
            // still resolve the symbol.
            _ = prompt
            throw LocalLLMError.foundationModelsUnavailable
        #endif
    }

    #if canImport(FoundationModels)
        /// **v0.12 W8-1 — streaming structured generation.** Returns the
        /// `ResponseStream` of `CoachInsight.PartiallyGenerated` snapshots so
        /// the AskCoach surface can render the headline → body → actions
        /// progressively instead of "spinner then wall of text." Each element
        /// is a cumulative partial (FoundationModels' contract: every snapshot
        /// supersedes the prior). The caller renders each partial with
        /// `complete: false` until the stream finishes, then commits the final
        /// content with `complete: true`.
        ///
        /// **Availability:** same gate as `respond` — re-probes synchronously
        /// and throws `.foundationModelsUnavailable` when the model isn't ready.
        /// Generation errors surface as the stream throwing, which the caller
        /// maps to `.modelResponseFailed`.
        @available(iOS 26.0, *)
        public func streamResponse(
            prompt: String
        ) throws -> LanguageModelSession.ResponseStream<CoachInsight> {
            applyAvailability(Self.probeAvailability())
            guard cachedAvailability == .available else {
                throw LocalLLMError.foundationModelsUnavailable
            }
            return session().streamResponse(
                to: prompt,
                generating: CoachInsight.self
            )
        }
    #endif

    // MARK: - Private

    /// Maps Apple's `SystemLanguageModel.Availability` to our internal
    /// `Availability` enum. Compiled-out on platforms where
    /// FoundationModels is not importable; returns `.unsupported` at
    /// runtime on iOS 18 / 25 because the `#available` check fails.
    private static func probeAvailability() -> Availability {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                let model = SystemLanguageModel.default
                switch model.availability {
                case .available:
                    return .available
                case let .unavailable(reason):
                    return map(unavailableReason: reason)
                }
            }
            return .unsupported
        #else
            return .unsupported
        #endif
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        private static func map(
            unavailableReason reason: SystemLanguageModel.Availability.UnavailableReason
        ) -> Availability {
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            case .deviceNotEligible:
                return .deviceNotEligible
            @unknown default:
                // Future Apple-added reasons collapse to the
                // device-ineligible kill-card branch — fail-closed so
                // the AskCoach hero never paints a "ready" badge while
                // FoundationModels is actually blocked for an unknown
                // reason.
                return .deviceNotEligible
            }
        }
    #endif
}

/// Error surface for `LocalLLMService.respond(prompt:)`.
///
/// **v0.5.7 G.2** adds `.foundationModelsUnavailable` (covers both
/// pre-iOS-26 and `availability != .available` runtime branches) and
/// `.modelResponseFailed(_:)` (wraps any
/// `LanguageModelSession.GenerationError` so the AskCoach UI can offer
/// a retry without re-importing FoundationModels).
public enum LocalLLMError: Error, Sendable {
    /// FoundationModels is not usable on this runtime — either the
    /// build is pre-iOS-26 (the framework is not linkable) or the
    /// runtime probe returned `.unavailable(...)` (Apple Intelligence
    /// disabled, model still downloading, device not eligible). The
    /// AskCoach hero gates on `LocalLLMService.isReady` and surfaces
    /// the kill-card before reaching this error in normal use.
    case foundationModelsUnavailable
    /// Wraps any error thrown by `LanguageModelSession.respond(...)`
    /// (safety refusal, context overflow, transient model errors). The
    /// associated value is the original error so the UI / `HLLog`
    /// breadcrumb retains full context without exposing
    /// FoundationModels types to call-sites.
    case modelResponseFailed(Error)
    /// **v0.13 W4** — wraps a ``BYOLLMError`` from the client-side BYO-key Coach
    /// arm so the AskCoach banner can render an honest, per-case message
    /// (invalid key → "check your key in Settings", unreachable, rate-limited)
    /// without a new view-layer error type. The associated value keeps the
    /// typed cause so the copy switch maps it precisely.
    case byoFailed(BYOLLMError)
    /// **C3 (b199 walkthrough)** — wraps a failure from the SERVER Coach arm
    /// (`runServerTurn`), mirroring `.byoFailed` for the BYO arm. Previously the
    /// server arm collapsed every failure into `.modelResponseFailed`, discarding
    /// the discriminating cause (`CoachServerError.provider(code)` for
    /// no-tokens/rate-limited, `HLError.assistantDisabled` / HTTP status, offline,
    /// missing consent receipt) so the banner could only ever say "Response
    /// failed. Please try again." The associated value keeps the typed cause so
    /// `serverErrorCopy` maps it to an actionable, localized message.
    case serverFailed(Error)
}

/// **22-02 (D-14-04-A) — the third outcome, made representable.**
///
/// A coach turn was modelled as having two endings: an assistant answer, or a
/// documented error. Under load the on-device runtime produced a third — the
/// generation stream completed having rendered nothing at all — and the store
/// had no way to say so: the user turn stood alone in the transcript with
/// `lastError == nil`, which reads exactly like "the model chose not to answer
/// you". The suite that was supposed to catch it could not even express the
/// case, so it asserted an either/or over two branches and passed.
///
/// The server arm has said this honestly since v0.7.1 (`CoachServerError`
/// `.emptyReply`) and the BYO adapters since v0.13 (`BYOLLMError.decode` on an
/// empty body). This is the on-device arm's equivalent word, folded into the
/// existing `.modelResponseFailed` case so no exhaustive error-copy switch
/// changes shape.
public struct LocalLLMEmptyGenerationError: Error, Sendable, Equatable {
    public init() {}
}
