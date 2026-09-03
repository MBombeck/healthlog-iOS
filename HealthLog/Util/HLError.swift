import Foundation

public enum HLError: Error, Sendable, Equatable {
    case network(Underlying)
    case server(status: Int, code: String?, message: String)
    case decoding(String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case canceled
    /// Server returned `403` with
    /// `errorCode: "assistant.disabled.<surface>"` (server brief
    /// v1.4.31 §5 + cross-coordination audit §c.1). The caller is
    /// expected to mirror the operator-state into
    /// `FeatureFlagsStore` and render the matching surface
    /// placeholder. Dispatch refers to this as
    /// `ServerError.assistantDisabled(surface:)` — we house it on
    /// `HLError` so the existing `APIClient` rejection path
    /// (`ensureSuccess` / `decodePayload`) and `HLErrorBanner` chain
    /// keep their single error type.
    case assistantDisabled(FeatureFlag)
    /// #30 / v1.18.0 — server returned `403` with `meta.errorCode ==
    /// "module.disabled"` + `meta.module: "<key>"`. The caller is expected to
    /// treat the associated module as *off* (hide its surface), NOT as a
    /// failure. `APIClient` mirrors the disabled key into ``ModuleGate`` on the
    /// same tick so the surface disappears; the typed error lets a caller that
    /// is mid-flight short-circuit gracefully. The associated value is the
    /// server `meta.module` wire key.
    case moduleDisabled(String)
    /// W-INTEGRITY-WRITEPATH G-2 — the optimistic write could **not** be made
    /// durable: the network attempt failed retriably *and* the Outbox enqueue
    /// that should have preserved it for replay ALSO failed (most acutely when
    /// the Outbox has degraded to the in-memory inert floor, where every
    /// `enqueue` throws). Nothing is queued — so the store MUST roll the
    /// optimistic state back and surface an honest "couldn't save" instead of a
    /// false "saved/queued". Deliberately `false` under `shouldPersistToOutbox`
    /// (re-enqueuing the thing that just failed to enqueue is pointless) and
    /// `false` under `isRetriable`. The associated string is a sanitized
    /// description of the enqueue failure for triage, never user-facing.
    case notPersisted(String)
    /// CU-20 (#69) — a guarded write (`baseUpdatedAt`) kept losing the race:
    /// the server returned `409` and the bounded conflict-retry loop in
    /// ``withOptimisticConflictRetry(conflictCode:maxAttempts:token:isolation:write:reread:)``
    /// gave up, either because the attempt budget was spent or because the
    /// post-409 re-GET returned the *same* token (the 300 s server-side layout
    /// cache is invalidated only by its own route's writes, so a re-read can
    /// legitimately stay stale and an unbounded loop would never terminate).
    ///
    /// **Nothing was written** — the 409 arm of `guardedUserUpdate` /
    /// `guardedRowUpdate` returns before touching the row. The caller MUST roll
    /// the optimistic UI back and surface an honest "couldn't save". Falling
    /// back to a tokenless write here would silently clobber whatever the other
    /// session wrote, which is the exact hazard the token exists to prevent.
    /// Non-retriable and NOT outbox-persisted (a replay would re-send the same
    /// stale token). The associated value is the route's conflict `errorCode`,
    /// for triage only — never user-facing.
    case writeConflictUnresolved(String)
    /// Es ist **kein Server eingerichtet** (`AppEnvironment.baseURL == nil`).
    ///
    /// Die App bringt keinen eingebauten Server mit; bis der Nutzer im
    /// Onboarding seine eigene Adresse einträgt, gibt es schlicht nichts,
    /// wogegen ein Request laufen könnte. Das ist ein Einrichtungszustand,
    /// kein Transportfehler — deshalb ein eigener Fall statt eines
    /// erfundenen Hosts, der als Netzwerkfehler an ganz anderer Stelle
    /// auftauchen würde. Nicht retriable, nicht outbox-persistiert (ein
    /// Replay hätte dasselbe Problem).
    case serverNotConfigured
    /// v1.35.0 (GH #83) — the server understood the request and **refused it
    /// with a stated reason**: `meta.errorCode` says which rule was missed,
    /// `meta.reason` says which arm of it. A separate case from
    /// `.server(422, …)` for two reasons. The refusal is an explanation the
    /// surface owes the person, not a failure it should apologise for; and the
    /// server's own prose is written for the web client, so the sentence has to
    /// be composed here from the reason rather than echoed from `message`.
    ///
    /// Produced **only** for the codes in ``APIRefusal/reasonedCodes`` — every
    /// other 422 that happens to carry a `meta.reason` (the document-inbox
    /// family) keeps arriving as `.server`, so no existing pattern match
    /// changes shape underneath it. Both values are raw wire strings; the
    /// domain maps the pair (see ``HealthScoreBreadthReason``).
    case refusedWithReason(code: String, reason: String)
    case unknown(String)

    public enum Underlying: Sendable, Equatable {
        case timeout
        case connectionLost
        case dnsFailure
        case sslPinning
        case other(String)
    }
}

public extension HLError {
    /// b182 W-B182-INVITE (GH #16) — does this error represent a rejected invite
    /// on the register call? On a closed-registration instance the server returns
    /// a `403` ("Invalid or expired invite" / "Registration is disabled") when
    /// the attached invite token is invalid/expired/exhausted. The onboarding
    /// `RegistrationSheet` maps this to a clear localized inline message instead
    /// of the raw server string. Only meaningful when an invite token WAS sent.
    var isInvalidInviteError: Bool {
        if case let .server(status, _, _) = self { return status == 403 }
        return false
    }

    /// #37/#38 — the server returned `401` with `errorCode: "auth.stepup.required"`,
    /// i.e. a fresh-MFA step-up is required that a native Bearer session structurally
    /// cannot satisfy (the step-up is cookie-only). Surfaced verbatim only for the
    /// paths in `APIClient.preserves401Body` (the account-delete DELETE); the
    /// account-delete flow uses it to route MFA users to the web deletion page
    /// instead of showing a misleading "please re-login".
    var isMfaStepUpRequired: Bool {
        if case .server(401, "auth.stepup.required", _) = self { return true }
        return false
    }

    var isRetriable: Bool {
        switch self {
        case .network, .offline:
            true
        case let .server(status, _, _):
            status >= 500 || status == 408
        case .rateLimited:
            true
        default:
            false
        }
    }

    /// Whether a failed optimistic write should be persisted to the Outbox for
    /// later replay, **as distinct from** `isRetriable` (which governs the
    /// in-request retry loop in `APIClient.execute`).
    ///
    /// Returns `true` for everything `isRetriable` covers
    /// (`.network`/`.offline`/`.rateLimited`/5xx/408) **plus `.unauthorized`**.
    ///
    /// **Why `.unauthorized` persists (the WC / D1 fix):** a mid-write token
    /// expiry yields a single-flight refresh; when that refresh fails
    /// *transiently* (`RefreshOutcome.transient`, e.g. the refresh call itself
    /// hit a network hiccup) `APIClient` throws `.unauthorized` **without**
    /// logging the user out. Gating the Outbox enqueue on `isRetriable` then
    /// silently DROPPED the optimistic write (lost measurement / mood /
    /// med-intake) — the exact watch-mood-vanishes bug. Persisting on
    /// `.unauthorized` instead lets the write survive: the replay carries the
    /// same persisted idempotency key, and even on a genuine `.tokenExpired`
    /// logout the row survives (that logout has `clearsOutbox == false`), so it
    /// replays once the SAME user re-authenticates — the row is stamped with
    /// the user who was signed in when the write was made (Build 273 / A2:
    /// `OutboxQueue.ownerProvider` falls back to `KeychainKey.lastSessionUserID`,
    /// because the terminal-401 wipe removes `userID` before this enqueue runs);
    /// under any other account it is retained, never transmitted. The 401 means
    /// the write never reached the server *authenticated*, and the idempotency
    /// key makes a later successful replay safe against double-write.
    ///
    /// **Why NOT `.decoding` / non-401 4xx / `.canceled` / `.assistantDisabled`
    /// / `.unknown`:** these are ambiguous or permanent. A 403/404/409/422 says
    /// the request was *understood and rejected* (forbidden / gone / conflict /
    /// invalid) — replaying it forever, or worse re-writing after the server
    /// already accepted-then-rejected, is strictly worse than surfacing the
    /// error. `.decoding` means we couldn't even read the response, so we don't
    /// know whether the write landed — enqueuing risks an unbounded replay of a
    /// request the server may have already applied. `.canceled` is user/system
    /// intent, not a failure to persist.
    /// `true` for a `403 + errorCode: "module.disabled"`.
    ///
    /// Server brief #56 (backend v1.30.19) made three aggregate surfaces honour
    /// the user's module switches. A caller that falls back to a LOCAL emitter on
    /// error must branch on this: a module refusal is a decision to respect, not
    /// a transport failure to route around.
    var isModuleDisabled: Bool {
        if case .moduleDisabled = self { return true }
        return false
    }

    var shouldPersistToOutbox: Bool {
        isRetriable || self == .unauthorized
    }

    var localizedDescription: String {
        switch self {
        case let .network(u): "Netzwerk-Fehler: \(u)"
        // v0.14.1 #3 — defense in depth: a 5xx carries an internal server
        // message (e.g. a leaked JS "x.map is not a function" TypeError) that
        // must never reach a user-facing surface. Mirror `userFacingDescription`
        // here so any remaining caller of `localizedDescription` for display
        // also gets a generic 5xx string; 4xx envelopes stay verbatim because
        // they carry server-localised, user-safe copy.
        case let .server(status, _, m):
            (500 ... 599).contains(status) ? userFacingDescription : m
        case let .decoding(s): "Server-Antwort konnte nicht gelesen werden: \(s)"
        case .unauthorized: "Bitte erneut anmelden."
        case .rateLimited: "Zu viele Anfragen. Versuch es später erneut."
        case .offline: "Kein Netzwerk."
        case .canceled: "Abgebrochen."
        case let .assistantDisabled(flag): "Funktion deaktiviert: \(flag.rawValue)"
        case let .moduleDisabled(module): "Modul deaktiviert: \(module)"
        case let .notPersisted(s): "Konnte nicht gespeichert werden: \(s)"
        case let .writeConflictUnresolved(code): "Schreibkonflikt ungelöst: \(code)"
        case let .refusedWithReason(code, reason): "Abgelehnt: \(code)/\(reason)"
        case .serverNotConfigured: "Kein Server eingerichtet."
        case let .unknown(s): s
        }
    }

    /// User-facing copy. Used by `ErrorBanner` and any UI surface that
    /// presents an error.
    ///
    /// **NEVER** leak raw `DecodingError` text — pre-v0.4.0 this returned
    /// `localizedDescription` which embedded
    /// `String(describing: DecodingError)` for `.decoding`, surfacing
    /// "Type mismatch ...", "Key not found ..." snippets to users
    /// (A4-Audit §7, acute report #5).
    var userFacingDescription: String {
        switch self {
        case .network(.timeout):
            String(localized: "Connection took too long. Please try again.")
        case .network:
            String(localized: "No connection. We'll retry automatically.")
        case .offline:
            String(localized: "Offline — showing cached values.")
        case .unauthorized:
            String(localized: "Sign-in expired. Please sign in again.")
        case .rateLimited:
            String(localized: "Too many requests. Please try again shortly.")
        case .canceled:
            ""
        case let .server(status, _, message) where (400 ... 499).contains(status):
            // 4xx envelopes carry a user-friendly message string from the server
            // (`apiError` already localises). Surface it verbatim.
            message
        case .server:
            String(localized: "Server error. We're looking into it.")
        case .decoding:
            // CRITICAL: never expose raw DecodingError text. The full text is
            // still logged via HLLog.api elsewhere with `LogSanitizer.redact`.
            String(localized: "Couldn't read the data. Please try again.")
        case .assistantDisabled:
            // Surface placeholder owns the user-facing copy
            // (`feature_disabled.title` / `feature_disabled.subtitle`).
            // Banner copy stays neutral so it can't render twice if a
            // caller both throws into the banner AND mounts the
            // placeholder card.
            String(localized: "feature_disabled.title")
        case .moduleDisabled:
            // #30 — the surface is hidden structurally once ModuleGate
            // mirrors the disabled key; the banner copy stays neutral so a
            // mid-flight caller doesn't surface a scary error for what is
            // simply a switched-off module.
            String(localized: "feature_disabled.title")
        case .notPersisted:
            // The write reached neither the server nor the durable outbox. Be
            // honest: the user's change was NOT saved and they should retry.
            String(localized: "Couldn't save your change. Please try again.")
        case .writeConflictUnresolved:
            // CU-20 — nothing was written because the surface changed elsewhere
            // (another device / the web session) while the edit was open. Be
            // honest and specific: a plain "try again" would read as a network
            // blip, when the actual instruction is "reopen, the data moved".
            String(localized: "This was changed somewhere else while you were editing. Reopen the screen and make your change again.")
        case .refusedWithReason:
            // The refusal is specific, and the surface that made the request
            // owns the sentence that explains it (it knows the domain, this
            // enum does not). This banner copy is the honest floor for a caller
            // that did NOT handle its own refusal: it says the entry was
            // refused, and never invents a reason.
            String(localized: "The server didn't accept this. Please check your entry and try again.")
        case .serverNotConfigured:
            // Kein Transportfehler, sondern ein Einrichtungszustand: die App
            // kennt noch keine Serveradresse. Die Kopie sagt genau das und
            // nennt den Weg dorthin, statt einen Verbindungsfehler zu
            // behaupten, den es nicht gibt.
            String(localized: "error.serverNotConfigured")
        case .unknown:
            String(localized: "Something went wrong. Please try again.")
        }
    }
}
