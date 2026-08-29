#if DEBUG
    import Foundation

    /// **W-HERMETIC-E2E (v0152).** Deterministic JSON fixtures served by
    /// ``HermeticURLProtocol``. Keyed by request path prefix.
    ///
    /// Design: rich fixtures for the LOAD-BEARING surfaces the seven UITest
    /// classes assert against (dashboard summary, measurements, feature-flags,
    /// the user `/me` row). Everything else falls through to a permissive
    /// empty-but-VALID default (`[]` for list-shaped routes, `{}` otherwise) so
    /// no decoder traps and every surface renders an empty-but-correct state
    /// instead of hitting the network. Debug-only by file wrap.
    enum HermeticFixtures {
        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem] = []
        ) -> (status: Int, body: Data) {
            // 12-12 second pass — the marketing-capture overlay outranks
            // everything, and exists only while `-uitest-marketing` is on the
            // command line (only `MarketingScreenshotsTest` passes it). It
            // answers a handful of paths (medications, today-intakes, the
            // dashboard summary) and returns `nil` for everything else, so
            // the scenario + default tables below are reached unchanged.
            if HermeticUITestSupport.isMarketingOverlayActive,
               let marketing = MarketingFixtures.response(forPath: path, method: method)
            {
                return marketing
            }
            // Phase 08 Wave 0 — the scenario-keyed answers come first and only
            // exist while `-uitest-phase8 <scenario>` is on the command line.
            // Outside a Phase-8 UI test this returns `nil` on every path and the
            // original table below is reached unchanged.
            if let scenario = HermeticUITestSupport.phase8Scenario,
               let phase8 = Phase8Fixtures.response(
                   forPath: path,
                   method: method,
                   query: query,
                   scenario: scenario
               )
            {
                return phase8
            }
            return defaultResponse(forPath: path, method: method)
        }

        private static func defaultResponse(forPath path: String, method: String) -> (status: Int, body: Data) {
            // H3 auth-journey (audit-v0162) — the real login + MFA-verify
            // endpoints, steered by launch args. Extracted so the main router's
            // cyclomatic complexity stays inside the lint budget. Checked FIRST
            // (these paths never overlap the `/api/auth/me` prefix below); only
            // reached in the auth-journey boot.
            if let authResponse = authResponse(forPath: path) { return authResponse }
            // Newest-first prefix match. Order matters for the `/api/insights`
            // family (specific before the family default).
            // 18-03 — the sharing family, extracted for the same reason the
            // auth family is: three more branches here would put the router
            // over its cyclomatic budget. Checked before `/api/auth/me`,
            // because the report-selection route sits under that prefix.
            if let sharing = sharingResponse(forPath: path, method: method) { return sharing }
            if let account = accountResponse(forPath: path) { return account }
            if path.hasPrefix("/api/dashboard/summary") { return ok(dashboardSummaryJSON) }
            if path.hasPrefix("/api/dashboard/snapshot") { return ok("{}") }
            if path.hasPrefix("/api/feature-flags") { return ok(featureFlagsJSON) }
            if path.hasPrefix("/api/measurements") { return ok(measurementsJSON) }
            if path.hasPrefix("/api/medications") { return ok("[]") }
            if path.hasPrefix("/api/cycle") { return ok(emptyArrayOrObject(forPath: path)) }
            if path.hasPrefix("/api/insights") { return ok(emptyArrayOrObject(forPath: path)) }
            if path.hasPrefix("/api/health") { return ok("{\"status\":\"ok\"}") }
            // 13-04 — `WebHandoffLogin.minimumServerVersion` is 1.32.11; under
            // `-uitest-weblogin` the fixture server is comfortably past it,
            // exactly like the operator's instance. Scoped to that argument on
            // purpose: serving it by default would put the browser CTA in front
            // of every auth-journey test and hide the password form those tests
            // are about. See `HermeticUITestSupport.webLoginRoutesArgument`.
            if path.hasPrefix("/api/version"), HermeticUITestSupport.servesWebLoginRoutes {
                return ok(serverVersionJSON)
            }
            // Permissive default: list-shaped paths get `[]`, everything else `{}`.
            return ok(emptyArrayOrObject(forPath: path))
        }

        // MARK: - Auth routing (H3 — audit-v0162)

        /// The login / MFA-verify / registration-status routes, steered by launch
        /// args so a UITest can drive password login, the MFA challenge sheet, and
        /// the wrong-code / dead-ticket branches with no network. Returns `nil`
        /// for a non-auth path so the caller falls through to the data fixtures.
        private static func authResponse(forPath path: String) -> (status: Int, body: Data)? {
            let args = ProcessInfo.processInfo.arguments
            if path.hasPrefix("/api/auth/login") {
                // An MFA-enrolled account: password accepted, second factor
                // required (`data: null` + `meta.mfaRequired`). Otherwise a full
                // token bundle → the shell.
                return args.contains("-uitest-mfa-challenge") ? ok(mfaChallengeJSON) : ok(sessionJSON)
            }
            if path.hasPrefix("/api/auth/mfa/verify") {
                // The server returns 401 for BOTH a wrong code and a dead ticket,
                // differing only in the body message (`APIClient.preserves401Body`
                // surfaces it). `AuthStore.handleMfaVerifyFailure` keeps the sheet
                // up for "Invalid code" (retry) and ejects to the password form for
                // "Invalid or expired challenge" (dead ticket).
                if args.contains("-uitest-mfa-verify-wrong") { return (401, Data(mfaWrongCodeJSON.utf8)) }
                if args.contains("-uitest-mfa-verify-dead") { return (401, Data(mfaDeadTicketJSON.utf8)) }
                return ok(sessionJSON)
            }
            if path.hasPrefix("/api/auth/registration-status") { return ok(registrationStatusJSON) }
            // 13-04 — the second route the web-handoff availability gate reads,
            // scoped to `-uitest-weblogin` for the reason given on the version
            // route above. A well-configured instance: the login route answers
            // on its own origin. The dead-end classification has eleven unit
            // cases of its own; what the UI test needs from here is a CTA.
            if path.hasPrefix("/api/auth/native/login"), HermeticUITestSupport.servesWebLoginRoutes {
                return ok("{}")
            }
            return nil
        }

        // MARK: - Helpers

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// The `/api/auth/me` family — the modules row before the account row,
        /// because the former sits under the latter's prefix. Extracted with the
        /// sharing family so the router's branch count comes out where it went
        /// in.
        private static func accountResponse(forPath path: String) -> (status: Int, body: Data)? {
            if path.hasPrefix("/api/auth/me/modules") { return ok(modulesJSON) }
            if path.hasPrefix("/api/auth/me") { return ok(meJSON) }
            return nil
        }

        /// **18-03 — the sharing family.** The unified sharing journey needs a
        /// real `share.leaves` vocabulary and a mintable link; both used to fall
        /// through to the permissive empty default, which renders the honest
        /// "your server served no selection list" state — correct, and useless
        /// to walk through. `nil` for every other path, so the table below is
        /// reached unchanged.
        private static func sharingResponse(
            forPath path: String,
            method: String
        ) -> (status: Int, body: Data)? {
            if path.hasPrefix("/api/meta/capabilities") { return ok(capabilitiesJSON) }
            if path.hasPrefix("/api/auth/me/report-selection") { return ok(reportSelectionJSON) }
            if path.hasPrefix("/api/share-links") {
                return method == "POST" ? ok(shareLinkCreatedJSON) : ok(shareLinkListJSON)
            }
            return nil
        }

        /// Heuristic empty body: plural / list-shaped routes decode an empty
        /// array; singular routes decode an empty object. Both are valid empty
        /// states for the corresponding decoders.
        ///
        /// One named exception, because "valid" is the whole promise of this
        /// helper: `/api/analytics?slice=summaries` decodes
        /// `MeasurementAvailabilityDTO`, whose `summaries` key is REQUIRED — the
        /// bare `{}` default was a decoder trap, and every hermetic boot's
        /// Insights strip wore 22-01's "Sections could not be loaded" line for a
        /// read that never genuinely failed. `{"summaries":{}}` is the honest
        /// empty answer a measurement-less account gets: availability resolves,
        /// and a resolved-empty read says nothing (statement nil).
        private static func emptyArrayOrObject(forPath path: String) -> String {
            if path.hasPrefix("/api/analytics") { return #"{"summaries":{}}"# }
            let listSuffixes = ["all", "cycles", "calendar", "day-logs", "cards", "episodes", "achievements", "passkeys", "devices"]
            if listSuffixes.contains(where: { path.hasSuffix($0) }) { return "[]" }
            return "{}"
        }

        // MARK: - Auth-journey fixtures (H3 — audit-v0162)

        /// `/api/auth/login` (no-MFA) and `/api/auth/mfa/verify` (correct code) —
        /// a full native token bundle wrapped in the server envelope
        /// (`{ data: { user, token, … } }`), decoded by `NativeLoginResponse`.
        /// Long-lived expiries so the session never looks stale mid-test.
        private static let sessionJSON = """
        {
          "data": {
            "user": {
              "id": "hermetic-user",
              "email": "hermetic@uitest.local",
              "username": "hermetic",
              "displayName": "Hermetic Tester",
              "createdAt": "2024-01-01T00:00:00.000Z"
            },
            "token": "hermetic-bearer-token",
            "tokenExpiresAt": "2099-01-01T00:00:00.000Z",
            "refreshToken": "hermetic-refresh-token",
            "refreshTokenExpiresAt": "2099-01-01T00:00:00.000Z"
          }
        }
        """

        /// `/api/auth/login` for an MFA-enrolled account: password accepted, no
        /// token yet, `meta.mfaRequired` + a single-use ticket + the offered
        /// factors. `AuthStore.login` raises the challenge that drives
        /// `MfaChallengeSheet`.
        private static let mfaChallengeJSON = """
        {
          "data": null,
          "meta": {
            "mfaRequired": true,
            "mfaTicket": "hermetic-mfa-ticket",
            "methods": ["totp", "recovery"]
          }
        }
        """

        /// `/api/auth/mfa/verify` — a WRONG code. 401 whose message carries
        /// neither "expired" nor "challenge", so `AuthStore` treats it as
        /// retriable and keeps the sheet up with an inline error.
        private static let mfaWrongCodeJSON = """
        { "error": "Invalid code" }
        """

        /// `/api/auth/mfa/verify` — a DEAD ticket. 401 whose message contains
        /// "expired"/"challenge", so `AuthStore` ejects the challenge back to the
        /// password form.
        private static let mfaDeadTicketJSON = """
        { "error": "Invalid or expired challenge" }
        """

        /// `/api/auth/registration-status` — registration off (keeps the auth
        /// step's "create account" CTA out of the way; the auth-journey boot
        /// bypasses the ServerURL probe that would otherwise fetch this).
        private static let registrationStatusJSON = """
        { "registrationEnabled": false }
        """

        /// 13-04 — `GET /api/version`, wrapped in the server envelope
        /// `ServerVersionInfo` decodes through.
        private static let serverVersionJSON = """
        { "data": { "version": "1.37.20" }, "error": null }
        """

        // MARK: - Fixtures

        /// `/api/auth/me` — minimal user row. `disclaimerAcknowledgedAt` is set so
        /// the disclaimer gate stays down even without the `-uitest-ack-disclaimer`
        /// flag. `onboardingTourCompleted: true` so the user is not re-dropped
        /// into setup.
        private static let meJSON = """
        {
          "id": "hermetic-user",
          "email": "hermetic@uitest.local",
          "username": "hermetic",
          "displayName": "Hermetic Tester",
          "createdAt": "2024-01-01T00:00:00.000Z",
          "disclaimerAcknowledgedAt": "2024-01-01T00:00:00.000Z",
          "onboardingTourCompleted": true,
          "moodReminderEnabled": false
        }
        """

        /// `/api/auth/me/modules` — all modules ON (the gate fails open anyway).
        private static let modulesJSON = """
        { "modules": {} }
        """

        /// `/api/meta/capabilities` — a small but REAL `share.leaves`
        /// vocabulary. The client never authors a leaf list, so a hermetic walk
        /// through the selection needs the server half to exist.
        private static let capabilitiesJSON = """
        { "apiContractVersion": "1.37.24",
          "share": { "supported": true, "maxDays": 90,
                     "reportDownload": ["fhir", "pdf"], "selectionVersion": 2,
                     "groups": ["vitals", "labs", "medications"],
                     "leaves": ["WEIGHT", "PULSE", "LAB_RESULTS", "MEDICATION_LIST"] } }
        """

        /// `GET /api/auth/me/report-selection` — deliberately `null`. E1.2's
        /// empty default is the state the journey has to be able to see.
        private static let reportSelectionJSON = """
        { "profile": null }
        """

        /// `POST /api/share-links` — one mintable link, with the one-time token
        /// and passphrase the reveal panel presents.
        private static let shareLinkCreatedJSON = """
        { "data": { "id": "sl_hermetic", "label": "Dr. Hermetic",
                    "rangeStart": "2026-05-23T00:00:00Z", "rangeEnd": null,
                    "resourceTypes": [], "allowFhirApi": false,
                    "expiresAt": "2026-09-21T00:00:00Z",
                    "createdAt": "2026-08-23T00:00:00Z",
                    "revokedAt": null, "lastAccessAt": null,
                    "accessCount": 0, "active": true, "protected": true,
                    "token": "hls_hermetic", "passphrase": "AAAA-BBBB-CCCC-DDDD",
                    "shareUrl": "https://uitest.hermetic.local/c/hls_hermetic",
                    "qrUrl": "https://uitest.hermetic.local/c/hls_hermetic#k=AAAA-BBBB-CCCC-DDDD",
                    "needsReselection": false, "documentOnly": false },
          "error": null }
        """

        /// `GET /api/share-links` — empty list; the journey mints, it does not
        /// inspect a seeded one.
        private static let shareLinkListJSON = """
        { "data": { "shareLinks": [] }, "error": null }
        """

        /// `/api/feature-flags` — cycle tracking ON so the cycle toggle surface
        /// is reachable; the rest default off (the store fails open).
        private static let featureFlagsJSON = """
        { "cycleTracking": true }
        """

        /// `/api/dashboard/summary` — deterministic greeting + three per-kind
        /// metric tiles (weight / blood-pressure / pulse) carrying sparklines, a
        /// steps tile with a day-cumulative, plus a sleep tile. The German tile
        /// labels resolve from `MetricKind` localization in-app; the values here
        /// are the load-bearing assertions for `WalkthroughDashboardTest`.
        ///
        /// The salutation is a parameter (12-12 second pass) so the marketing
        /// overlay can serve the SAME summary with an empty one —
        /// `DashboardHeader` then renders its bare "Hi" fallback — without
        /// duplicating the metric table this default is asserted against.
        private static let dashboardSummaryJSON = dashboardSummaryJSON(salutation: "Hermetic Tester")

        static func dashboardSummaryJSON(salutation: String) -> String {
            """
            {
              "greeting": { "salutation": "\(salutation)", "date": "2026-06-16T08:00:00.000Z" },
              "compliance": { "scheduledToday": 2, "takenToday": 1 },
              "highlightInsight": null,
              "metrics": [
                {
                  "id": "weight", "kind": "weight", "title": "Gewicht",
                  "latestValue": 72.4, "secondaryValue": null, "unit": "kg",
                  "trend": "down", "sparkline": [73.1, 72.9, 72.6, 72.5, 72.4],
                  "updatedAt": "2026-06-16T07:00:00.000Z"
                },
                {
                  "id": "bloodPressure", "kind": "bloodPressure", "title": "Blutdruck",
                  "latestValue": 122, "secondaryValue": 78, "unit": "mmHg",
                  "trend": "flat", "sparkline": [120, 124, 121, 123, 122],
                  "updatedAt": "2026-06-16T07:00:00.000Z"
                },
                {
                  "id": "pulse", "kind": "pulse", "title": "Puls",
                  "latestValue": 64, "secondaryValue": null, "unit": "bpm",
                  "trend": "flat", "sparkline": [66, 65, 64, 63, 64],
                  "updatedAt": "2026-06-16T07:00:00.000Z"
                },
                {
                  "id": "steps", "kind": "steps", "title": "Schritte",
                  "latestValue": 8421, "secondaryValue": null, "unit": "steps",
                  "trend": "up", "sparkline": [6200, 7100, 8000, 8421],
                  "updatedAt": "2026-06-16T07:00:00.000Z"
                },
                {
                  "id": "sleep", "kind": "sleep", "title": "Schlaf",
                  "latestValue": 7.2, "secondaryValue": null, "unit": "h",
                  "trend": "flat", "sparkline": [6.8, 7.0, 7.4, 7.2],
                  "updatedAt": "2026-06-16T07:00:00.000Z"
                }
              ],
              "lastUpdated": "2026-06-16T08:00:00.000Z"
            }
            """
        }

        /// `/api/measurements` — a small deterministic set so the per-metric
        /// detail surfaces + sparklines hydrate without network. Empty-valid for
        /// CI; rich enough for the chart/detail walkthroughs.
        private static let measurementsJSON = """
        []
        """
    }

    // MARK: - Phase 08 scenario fixtures

    /// **Phase 08 Wave 0.** The scenario-keyed half of the hermetic backend.
    ///
    /// Every answer here is owned by exactly one launch scenario, so a UI RED
    /// can state the shape of the world it needs instead of arranging it by
    /// tapping. `nil` means "this scenario has nothing to say about this route",
    /// which falls through to the existing permissive fixture table — so a
    /// Phase-8 boot is the ordinary hermetic boot plus a named difference.
    ///
    /// The only latency in the whole vocabulary is
    /// ``HermeticUITestSupport/Phase8Scenario/documentsDelayedFilter``, and it
    /// is deliberate: "the newest filter is still loading" is not a state a UI
    /// test can otherwise stand in. It sleeps on the URL-loading thread, never
    /// on the main actor and never inside a test.
    enum Phase8Fixtures {
        /// How long the delayed-filter scenario holds the newest answer. Long
        /// enough that the assertion window sits comfortably inside it.
        static let delayedFilterSeconds: TimeInterval = 4

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem],
            scenario: HermeticUITestSupport.Phase8Scenario
        ) -> (status: Int, body: Data)? {
            switch scenario {
            case .documentsModuleDisabled:
                guard path.hasPrefix("/api/documents/inbound") else { return nil }
                return (403, Data(moduleDisabledJSON.utf8))
            case .documentsDelayedFilter, .documentsPartialBulk:
                guard path.hasPrefix("/api/documents/inbound") else { return nil }
                return documentResponse(forPath: path, method: method, query: query, scenario: scenario)
            case .onboardingProfileFailure:
                // The optional profile write is refused, so the step's own
                // failure surface is exercised alongside its missing validation.
                // The step is reached through the setup tail, so this scenario
                // also has to say the setup is outstanding (08-08).
                if let outstanding = outstandingSetup(forPath: path) { return outstanding }
                // **08-10 — the refusal named a route the app never calls.**
                // `BaselineProfileStep` writes through `SettingsStore` →
                // `DashboardRepository.patchProfile`, which is
                // `PATCH /api/user/profile`; `/api/auth/profile` is the *web*
                // onboarding's `PUT`, quoted in this file's and the step's doc
                // comments and never issued by iOS. So this scenario's own name
                // was never true: every write it was supposed to refuse
                // succeeded, the step advanced, and the "preservation half" the
                // RED claims to hold — a refused write surfaces
                // `onboarding.baselineProfile.saveFailed` and does not advance —
                // was never once walked. Both routes are refused now; the web
                // one stays because the doc comments name it.
                guard profileWritePaths.contains(where: path.hasPrefix), method != "GET" else { return nil }
                return (500, Data(profileRefusedJSON.utf8))
            case .returningLoginIncomplete:
                return outstandingSetup(forPath: path)
            case .insightsAccessibility:
                // 08-11 — only the derived BATCH route, which is the one the
                // overview's score grid reads (`DerivedInsightsStore` →
                // `DerivedMetricsRepository.fetchBatch`). Everything else,
                // including the rest of `/api/insights`, keeps the permissive
                // default so the surface under test is the grid and not a
                // half-populated screen.
                guard path.hasPrefix("/api/insights/derived/batch") else { return nil }
                return ok(derivedBatchJSON)
            case .releaseSurface, .returningLoginCompleted:
                return nil
            }
        }

        /// `/api/auth/me` for an account whose setup is genuinely unfinished.
        ///
        /// **08-08.** Identical to the default row except for one field, and that
        /// field is now load-bearing: the post-authentication route reads it, so
        /// a case that needs the optional tail has to say so instead of relying
        /// on the flow to walk it regardless. Every other route falls through.
        private static func outstandingSetup(forPath path: String) -> (status: Int, body: Data)? {
            guard path.hasPrefix("/api/auth/me"), !path.hasPrefix("/api/auth/me/modules") else { return nil }
            return ok(incompleteTourMeJSON)
        }

        private static func documentResponse(
            forPath path: String,
            method: String,
            query: [URLQueryItem],
            scenario: HermeticUITestSupport.Phase8Scenario
        ) -> (status: Int, body: Data)? {
            // The partial-bulk world is also the world in which the upload
            // sheet has something true to say before a file is picked: its
            // quota has no headroom left, so every source is already refused.
            // Without that, "a failed import is visibly reported" is a claim no
            // hermetic case can make — the file picker is a system surface a
            // UITest must not drive.
            if path.hasSuffix("/usage") {
                return ok(scenario == .documentsPartialBulk ? fullQuotaUsageJSON : usageJSON)
            }
            if path.hasSuffix("/bulk"), method == "POST" { return ok(partialBulkJSON) }
            guard path == "/api/documents/inbound", method == "GET" else { return nil }
            let search = query.first { $0.name == "q" }?.value ?? ""
            if search.isEmpty { return ok(listJSON(ids: ["alpha", "beta"])) }
            if search.localizedCaseInsensitiveContains("beta") {
                if scenario == .documentsDelayedFilter {
                    Thread.sleep(forTimeInterval: delayedFilterSeconds)
                }
                return ok(listJSON(ids: ["beta"]))
            }
            return ok(listJSON(ids: ["alpha"]))
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// The two documents the Phase-8 UI REDs name. Titles are literal ASCII
        /// so a UITest can match them without a localisation lookup.
        static let documentTitles = ["alpha": "Alpha Report", "beta": "Beta Report"]

        private static func listJSON(ids: [String]) -> String {
            let rows = ids.map { id in
                """
                {"id":"doc-\(id)","kind":"LAB_RESULT","title":"\(documentTitles[id] ?? id)",
                 "filename":"\(id).pdf","mimeType":"application/pdf","byteSize":1024,"status":"STORED",
                 "providerType":null,"reportDate":null,"documentDate":"2026-05-01","errorReason":null,
                 "factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
                 "createdAt":"2026-05-01T09:00:00.000Z","updatedAt":"2026-05-01T09:00:00.000Z"}
                """
            }
            return #"{"data":{"documents":[\#(rows.joined(separator: ","))],"nextCursor":null},"error":null}"#
        }

        private static let usageJSON = #"""
        {"data":{"usedBytes":2048,"quotaBytes":1048576,"maxFileBytes":524288,
         "acceptedExtensions":[".pdf"],"linkedEpisodes":[]},"error":null}
        """#

        /// A vault with nothing left. Used only by the partial-bulk scenario.
        private static let fullQuotaUsageJSON = #"""
        {"data":{"usedBytes":1048576,"quotaBytes":1048576,"maxFileBytes":524288,
         "acceptedExtensions":[".pdf"],"linkedEpisodes":[]},"error":null}
        """#

        /// One id applied, one refused — the partial the bulk bar has to report
        /// without dropping the refused id out of the selection.
        private static let partialBulkJSON = #"""
        {"data":{"results":[{"id":"doc-alpha","ok":true,"error":null},
         {"id":"doc-beta","ok":false,"error":"notFound"}]},"error":null}
        """#

        /// **08-11.** `/api/insights/derived/batch` — four `status: ok` wellness
        /// scores, which is what the Insights overview's score grid renders as
        /// ring tiles. Four (not two) so a one-column fallback is unambiguous:
        /// at an accessibility text size the grid must be four rows where the
        /// standard grid is two.
        ///
        /// Values are invented and deliberately unremarkable — no health value
        /// of any real person appears in this repository's fixtures.
        static let derivedBatchMetrics = ["READINESS", "SLEEP_SCORE", "STRAIN_SCORE", "RECOVERY_SCORE"]

        private static let derivedBatchJSON = """
        {"data":{"metrics":{
        \(derivedBatchMetrics.enumerated().map { index, id in derivedMetricJSON(id: id, score: 62 + index * 7) }
            .joined(separator: ","))
        }},"error":null}
        """

        private static func derivedMetricJSON(id: String, score: Int) -> String {
            """
            "\(id)":{"metric":"\(id)","status":"ok",
             "value":{"score":\(score),"band":"green","trendDelta":2},
             "coverage":{"requiredInputs":4,"presentInputs":4,"historyDays":30,"missing":[]},
             "confidence":{"score":88,"band":"high"},
             "provenance":{"inputs":["rhr","hrv"],"source":"DAY","windowDays":30,
              "computedAt":"2026-06-16T07:00:00.000Z"},
             "reason":null,"assessment":null,"revalidating":false}
            """
        }

        private static let moduleDisabledJSON = #"""
        {"data":null,"error":"off","meta":{"errorCode":"module.disabled","module":"inboundDocuments"}}
        """#

        private static let profileRefusedJSON = #"""
        {"data":null,"error":"profile write refused"}
        """#

        /// Every route a profile write can take. `/api/user/profile` is the one
        /// iOS actually issues (`DashboardRepository.patchProfile`);
        /// `/api/auth/profile` is the web onboarding's `PUT` and is kept so the
        /// scenario stays true to the doc comments that name it.
        private static let profileWritePaths = ["/api/user/profile", "/api/auth/profile"]

        /// The default `/api/auth/me` row with the one field that decides the
        /// post-authentication route flipped to `false` (08-08). Everything else
        /// — the acknowledged disclaimer above all — is identical, so a case
        /// using this scenario differs from the default boot in exactly one
        /// stated way.
        private static let incompleteTourMeJSON = """
        {
          "id": "hermetic-user",
          "email": "hermetic@uitest.local",
          "username": "hermetic",
          "displayName": "Hermetic Tester",
          "createdAt": "2024-01-01T00:00:00.000Z",
          "disclaimerAcknowledgedAt": "2024-01-01T00:00:00.000Z",
          "onboardingTourCompleted": false,
          "moodReminderEnabled": false
        }
        """
    }
#endif
