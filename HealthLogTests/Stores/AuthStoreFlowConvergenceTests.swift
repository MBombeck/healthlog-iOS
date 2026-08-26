// **Phase 09 / plan 09-07 — the six authentication flows, held to one contract.**
//
// `AuthStore` grew six ways into the same state: password, MFA, registration,
// passkey, native OIDC SSO and the hosted web-handoff login each carried their
// own copy of "raise the spinner, clear the banner, publish the session, map the
// error, lower the spinner". Six copies of a transition are six chances for one
// of them to drift — and, more sharply, six unfenced publications: a result that
// arrives after the attempt that asked for it stopped being the current one.
//
// This file holds the clauses that are true **before and after** the extraction:
// the begin state, the benign-cancellation classification, the terminal-error
// mapping, the untouched five-field credential persistence, and the enumeration
// of every route that admits an authenticated phase. The two clauses the
// extraction exists to make true live in the sibling `+Fences` file.
//
// Nothing here is timed. Every figure is a count, a state or an ordering.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("AuthStore cross-flow convergence (09-07)", .serialized)
    struct AuthStoreFlowConvergenceTests {
        @Test("begin clears the transient error and raises the working state, in all six flows")
        func beginClearsTheTransientErrorAndRaisesTheWorkingState() async {
            var bannersWhileWorking: [Phase09AuthFlow: HLError?] = [:]
            var workingWhileParked: [Phase09AuthFlow: Bool] = [:]
            var parkedAtAcceptance: [Phase09AuthFlow: Bool] = [:]

            for flow in Phase09AuthFlow.allCases {
                let harness = Phase09AuthHarness(flow: flow, acceptanceStatus: 503)
                // A first, failing run leaves a banner on the form — the state a
                // second attempt has to clear.
                await harness.run()
                #expect(harness.store.lastError != nil, "\(flow.rawValue) published no banner to clear")

                let gate = Phase09Gate()
                harness.rescriptAcceptance(gate: gate)
                let running = Task { @MainActor in await harness.complete() }
                parkedAtAcceptance[flow] = await phase09Settle { gate.waitingCount == 1 }
                // Sampled while the flow is parked at its acceptance hop: this is
                // what the user is looking at mid-attempt.
                workingWhileParked[flow] = harness.store.isWorking
                bannersWhileWorking[flow] = harness.store.lastError
                gate.open()
                await running.value
                #expect(!Task.isCancelled)
            }

            #expect(parkedAtAcceptance.values.allSatisfy { $0 }, "a flow never reached its acceptance hop")
            #expect(workingWhileParked.count == 6)
            #expect(workingWhileParked.values.allSatisfy { $0 }, "a flow did not enter the working state")
            #expect(bannersWhileWorking.values.allSatisfy { $0 == nil }, "a flow kept a stale banner up")
        }

        @Test("benign cancellations stop the spinner without a banner, native and hosted alike")
        func benignCancellationsLeaveNoBanner() async {
            // 1) native SSO sheet dismissed, 2) hosted web-login sheet dismissed.
            for flow in [Phase09AuthFlow.nativeSSO, .hostedWebLogin] {
                let harness = Phase09AuthHarness(flow: flow, webAuthOutcome: .canceled)
                await harness.run()
                #expect(harness.store.lastError == nil, "\(flow.rawValue) raised a banner on a user cancel")
                #expect(harness.store.isWorking == false)
                #expect(harness.store.phase == .unknown)
                #expect(harness.storedBearer == nil)
            }

            // 3) the system passkey sheet dismissed without a selection.
            let passkey = Phase09AuthHarness(flow: .passkey, passkeyError: ASAuthorizationError(.canceled))
            await passkey.run()
            #expect(passkey.store.lastError == nil)
            #expect(passkey.store.isWorking == false)
            #expect(passkey.store.phase == .unknown)

            // 4) the security-key SECOND factor dismissed: benign, and the
            //    challenge deliberately stays up so the user can pick TOTP.
            let securityKey = Phase09AuthHarness(flow: .mfa, passkeyError: ASAuthorizationError(.canceled))
            await securityKey.prepare()
            #expect(securityKey.store.mfaChallenge != nil)
            await securityKey.store.verifyMFAWithSecurityKey(anchor: securityKey.anchor)
            #expect(securityKey.store.lastError == nil)
            #expect(securityKey.store.isWorking == false)
            #expect(securityKey.store.mfaChallenge != nil, "a benign cancel must not tear the challenge down")
            #expect(securityKey.store.phase == .unknown)
        }

        @Test("every terminal catch leaves no spinner and publishes the flow's mapped error")
        func everyTerminalCatchLeavesNoSpinnerAndPublishesTheMappedError() async {
            var spinnersLeftUp: [String] = []
            var wrongErrors: [String] = []

            for flow in Phase09AuthFlow.allCases {
                let harness = Phase09AuthHarness(
                    flow: flow,
                    acceptanceStatus: 503,
                    acceptanceMessage: "scripted outage"
                )
                await harness.run()

                if harness.store.isWorking { spinnersLeftUp.append(flow.rawValue) }
                let expected = flow.mappedTerminalError(status: 503, message: "scripted outage")
                if harness.store.lastError != expected { wrongErrors.append(flow.rawValue) }
                // A terminal error never moves the phase and never leaves a token.
                #expect(harness.store.phase == .unknown, "\(flow.rawValue) moved the phase on a failure")
                #expect(harness.storedBearer == nil)
            }

            #expect(spinnersLeftUp.isEmpty, "flows that left the spinner up: \(spinnersLeftUp)")
            #expect(wrongErrors.isEmpty, "flows that published an unmapped error: \(wrongErrors)")
        }

        @Test("atomic five-field credential persistence is behaviourally unchanged")
        func atomicCredentialPersistenceIsUnchanged() async {
            // Happy path: all five fields plus the cold-launch display-name hint.
            let happy = Phase09AuthHarness(flow: .password)
            await happy.run()
            #expect(happy.keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_user-password")
            #expect(happy.keychain.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_user-password")
            #expect(happy.keychain.getString(forKey: KeychainKey.userID) == "user-password")
            #expect(happy.keychain.getString(forKey: KeychainKey.accessTokenExpiresAt) != nil)
            #expect(happy.keychain.getString(forKey: KeychainKey.refreshTokenExpiresAt) != nil)
            #expect(happy.keychain.getString(forKey: KeychainKey.userDisplayName) == "convergence")

            // Partial failure: the refresh-token write throws mid-persist. The
            // previous credential set must survive whole — a split state hands
            // the next refresh a burned token and signs the user out everywhere.
            let keychain = Phase09AuthFailingKeychain()
            try? keychain.setString("hlk_bearer_OLD", forKey: KeychainKey.authToken)
            try? keychain.setString("hlr_refresh_OLD", forKey: KeychainKey.refreshToken)
            try? keychain.setString("user-old-1", forKey: KeychainKey.userID)
            let harness = Phase09AuthHarness(flow: .password, keychain: keychain)
            keychain.refuse(KeychainKey.refreshToken)

            await harness.run()

            #expect(keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_OLD")
            #expect(keychain.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_OLD")
            #expect(keychain.getString(forKey: KeychainKey.userID) == "user-old-1")
            #expect(harness.store.lastError != nil)
            #expect(harness.store.phase == .unknown, "a failed persist must not admit a phase")
            #expect(harness.store.isWorking == false)
        }

        @Test("every route that admits an authenticated phase is enumerated")
        func everyRouteThatAdmitsAnAuthenticatedPhaseIsEnumerated() throws {
            // 09-05's rule, applied to acceptance: before claiming that one
            // transition owns the admitted phase, list every production site
            // that assigns one. Verdicts are bound to `Bool`s first so no file
            // body can reach the log.
            let admitting = try FirstFrameSignalTests.productionFiles(naming: "phase = .authenticat")
            let inventoryIsExact = admitting == ["HealthLog/Stores/AuthStore.swift"]

            let root = Phase09SignpostContractTests.repositoryRoot()
            let storeSource = try FirstFrameSignalTests.withoutCommentLines(
                String(contentsOf: root.appendingPathComponent("HealthLog/Stores/AuthStore.swift"), encoding: .utf8)
            )
            // The four in-file writers, each of which is deliberately NOT a
            // login flow's acceptance and therefore outside this plan's fence:
            //   1. `bootstrap()` — a cold launch rehydrating a stored token,
            //      under the account boundary.
            //   2. `completeOnboarding()` — the terminal `.authenticating` →
            //      `.authenticated` promotion, guarded by its own phase check.
            //   3. `applySharingRecoveryUser(_:)` — refreshes the carried actor
            //      in place; it changes no phase case and carries a same-owner
            //      guard in `handleSharingRecovery(_:)`.
            //   4. `setPhaseForTesting(_:)` — DEBUG-only, never in Release.
            let inFileWriters = [
                "func bootstrap()",
                "func completeOnboarding()",
                "func applySharingRecoveryUser(",
                "func setPhaseForTesting("
            ]
            let writersAreOwned = inFileWriters.allSatisfy {
                FirstFrameSignalTests.occurrences(of: $0, in: storeSource) == 1
            }
            let testSeamIsDebugOnly = FirstFrameSignalTests.occurrences(of: "#if DEBUG", in: storeSource) == 1

            // The one seam every other file reaches an admitted phase through.
            // Two production files may name it: the funnel's own, and the fenced
            // transition that is its single caller.
            let funnelRoutes = try FirstFrameSignalTests.productionFiles(naming: "admitAuthenticating(")
            let funnelIsOwned = funnelRoutes == [
                "HealthLog/Stores/AuthStore+Phase.swift",
                "HealthLog/Stores/AuthStore.swift"
            ]

            #expect(inventoryIsExact, "the admitting-file inventory moved: \(admitting.count) files")
            #expect(writersAreOwned)
            #expect(testSeamIsDebugOnly)
            #expect(funnelIsOwned, "the admission funnel inventory moved: \(funnelRoutes.count) files")
        }
    }

#endif // !SWIFT_PACKAGE
