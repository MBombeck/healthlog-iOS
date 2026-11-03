#if DEBUG
    import Foundation

    extension HermeticFixtures {
        /// **1.4 B4 — the integration status routes answer like the server.**
        /// The permissive `{}` default is not a valid status: the real
        /// `GET /api/withings/status` and `/api/whoop/status` always send
        /// `connected` (and `configured`), so `{}` failed to decode and the
        /// screens showed the decoder's text under a pill stuck on
        /// "Checking". A hermetic account has neither provider linked:
        /// Withings has its credentials (the connect step), WHOOP has none
        /// (the credentials step), and so do Oura, Polar, Fitbit, Strava and
        /// Nightscout, whose list pills otherwise stayed on "Checking" too.
        /// B4-z adds the other routes the screenshot set caught answering
        /// `{}` where the server sends a shape: the sync handshake, the
        /// two-factor status, the MCP and API token lists and More → Workouts.
        /// `nil` for every other path.
        static func integrationStatusResponse(forPath path: String) -> (status: Int, body: Data)? {
            if path.hasPrefix("/api/withings/status") {
                return (200, Data(#"{"connected":false,"configured":true}"#.utf8))
            }
            let providers = ["whoop", "oura", "polar", "fitbit", "strava", "nightscout"]
            if providers.contains(where: { path.hasPrefix("/api/\($0)/status") }) {
                return (200, Data(#"{"connected":false,"configured":false}"#.utf8))
            }
            // The same class of gap on the Settings hub: `{}` is no
            // `AIProviderConfig` (its key flags are required), so every
            // Settings picture wore the red "Daten konnten nicht gelesen
            // werden" banner. A server without a configured provider answers
            // this. (`-uitest-citations` answers first with a configured one.)
            if path.hasPrefix("/api/user/ai-provider") {
                return (200, Data(Self.noAIProviderJSON.utf8))
            }
            // 1.4 B4 — the sync handshake. `{}` is no `ServerSyncStateDTO`
            // (`userId`, `serverNow`, `measurements` are required), so every
            // pull-to-refresh of a walk "failed" and each page after it wore
            // the sync footer's failure line. A reachable server answers this.
            if path.hasPrefix("/api/sync/state") {
                return (200, Data(Self.syncStateJSON().utf8))
            }
            // B4-z — the other routes the screenshot set caught answering
            // `{}` where the server sends a shape (see `emptyAccountAnswers`).
            if let body = Self.emptyAccountAnswers[path] {
                return (200, Data(body.utf8))
            }
            return nil
        }

        /// What the server answers on these read routes for an account with
        /// nothing there yet. Exact paths: the `{}` default is no valid shape
        /// for any of them, so each page photographed a "could not be read"
        /// state instead of its own empty one.
        static let emptyAccountAnswers: [String: String] = [
            // Konto → Sicherheit: the two-factor status sits under the
            // `/api/auth/me` prefix, which the account table answers with the
            // user row.
            "/api/auth/me/mfa": """
            { "totp": { "enabled": false }, "recoveryCodesRemaining": 0,
              "webauthn": [], "passkeyNudgeDismissed": false }
            """,
            // MCP and API tokens: list routes the `[]` suffix table misses.
            "/api/mcp/connections": "[]",
            "/api/mcp/tokens": "[]",
            "/api/tokens": "[]",
            // Coach → "Kontext für den Coach": nothing stored, the server's caps.
            "/api/coach/about-me": """
            { "aboutMe": null, "conditions": null, "allergies": null, "coachFocus": null,
              "pendingQuestions": [], "updatedAt": null, "maxChars": 4000, "fieldMaxChars": 500 }
            """,
            // Mehr → Workouts: an empty page, not a red banner over a black strip.
            "/api/workouts": """
            { "workouts": [], "meta": { "total": 0, "limit": 50, "offset": 0, "droppedDuplicates": 0 } }
            """
        ]

        static func syncStateJSON(now: Date = .now) -> String {
            let stamp = ISO8601DateFormatter().string(from: now)
            return """
            { "userId": "hermetic-user", "timezone": "\(TimeZone.current.identifier)",
              "lastSyncedAt": "\(stamp)", "serverNow": "\(stamp)",
              "measurements": { "lastUpdatedAt": "\(stamp)", "liveCount": 0, "tombstonedCount": 0 } }
            """
        }

        static let noAIProviderJSON = """
        { "provider": null, "model": null, "baseUrl": null,
          "hasAnthropicKey": false, "anthropicKeyPreview": null,
          "hasOpenaiKey": false, "openaiKeyPreview": null,
          "hasLocalKey": false, "aiAvailable": false }
        """
    }
#endif
