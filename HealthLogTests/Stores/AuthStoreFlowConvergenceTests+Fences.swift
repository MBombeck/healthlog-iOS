// **Phase 09 / plan 09-07 — the two clauses the extraction exists to make true.**
//
// An extension of `AuthStoreFlowConvergenceTests`, in a sibling file, so the
// suite stays one type and one `-only-testing:` selector.
//
// Both clauses are about the same thing from two sides: an authentication
// result is *perishable*. It is asked for at one instant and arrives at
// another, and everything that can happen in between — a second attempt, a
// standalone choice, a terminal 401 — has to be able to refuse it.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    extension AuthStoreFlowConvergenceTests {
        @Test("all six session flows publish through one fenced acceptance transition")
        func allSessionFlowsUseOneAcceptanceTransition() async {
            // ── The control: unimpeded, every flow lands in the same state ──
            //
            // Without it, "nothing published" would be satisfied by a store that
            // never publishes at all, which is not the contract.
            var acceptedPhases: [String] = []
            for flow in Phase09AuthFlow.allCases {
                let harness = Phase09AuthHarness(flow: flow)
                await harness.run()

                #expect(harness.store.phase == .authenticating(harness.expectedUser), "\(flow.rawValue) phase")
                #expect(harness.store.isWorking == false, "\(flow.rawValue) spinner")
                #expect(harness.store.lastError == nil, "\(flow.rawValue) banner")
                #expect(harness.store.mfaChallenge == nil, "\(flow.rawValue) challenge")
                // One admission per accepted session — the epoch `phase`'s own
                // `didSet` maintains and the shared session registry rides on.
                #expect(harness.store.authSessionGeneration == 1, "\(flow.rawValue) admission epoch")
                #expect(harness.storedBearer == "hlk_bearer_\(harness.userID)")

                // …and the same terminal onboarding promotion, from all six.
                harness.store.completeOnboarding()
                #expect(harness.store.phase == .authenticated(harness.expectedUser))
                acceptedPhases.append(flow.rawValue)
            }
            #expect(acceptedPhases.count == 6)

            // ── The clause: an account decision taken mid-flight is honoured ──
            //
            // `enterStandaloneMode()` is the user choosing local-only. It takes
            // no authentication boundary and moves neither the attempt epoch nor
            // the admission epoch — nil owner before, nil owner after — so it is
            // exactly the same-generation account change a generation alone
            // cannot catch, and only a transition that re-reads the situation it
            // began in can refuse the session that lands afterwards.
            var unfenced: [String] = []
            for flow in Phase09AuthFlow.allCases {
                let gate = Phase09Gate()
                let harness = Phase09AuthHarness(flow: flow, acceptanceGate: gate)
                await harness.prepare()
                let running = Task { @MainActor in await harness.complete() }
                let parked = await phase09Settle { gate.waitingCount == 1 }
                #expect(parked, "\(flow.rawValue) never reached its acceptance hop")

                harness.store.enterStandaloneMode()
                gate.open()
                await running.value

                if harness.store.phase != .standalone { unfenced.append(flow.rawValue) }
            }

            // Never the case's own task — a case that cancels itself is reported
            // by Swift Testing as a skip inside a run that prints "N passed".
            #expect(!Task.isCancelled)
            #expect(
                unfenced.isEmpty,
                "EXPECTED_RED: authentication flows do not share one acceptance transition"
            )
        }

        @Test("a late authentication attempt cannot overwrite a newer one")
        func lateAttemptCannotOverwriteNewerAttempt() async throws {
            var overwrites: [String] = []

            // ── Fence 1: two overlapping web-auth attempts on one store ──
            //
            // `loginWithWebLogin` and `loginWithSSO` deliberately hold no
            // account boundary while their sheet is up (holding it across an
            // unbounded modal would block sign-out and deletion for the sheet's
            // whole life), so they are the two flows that genuinely overlap.
            // The older one finishing must not touch the newer one's state.
            let sheetGate = Phase09Gate()
            let exchangeGate = Phase09Gate()
            let harness = Phase09AuthHarness(flow: .hostedWebLogin)
            harness.authenticator.enqueue(.failed, gate: sheetGate)
            try harness.authenticator.enqueue(.callback(#require(Phase09AuthFlow.nativeSSO.callbackURL)))
            harness.api.script(
                "/api/auth/oidc/native/token",
                .init(body: Phase09AuthBody.bundle(userID: harness.userID), gate: exchangeGate)
            )

            let older = Task { @MainActor in await harness.store.loginWithWebLogin(anchor: harness.anchor) }
            let sheetIsUp = await phase09Settle { sheetGate.waitingCount == 1 }
            #expect(sheetIsUp, "the older attempt never opened its sheet")
            let newer = Task { @MainActor in await harness.store.loginWithSSO(anchor: harness.anchor) }
            let newerIsParked = await phase09Settle { exchangeGate.waitingCount == 1 }
            #expect(newerIsParked, "the newer attempt never reached its hop")
            #expect(harness.store.isWorking, "the newer attempt is the one working")

            sheetGate.open()
            await older.value
            // Sampled while the newer attempt is still parked: this is the state
            // the user is looking at.
            if !harness.store.isWorking { overwrites.append("late attempt lowered the newer attempt's spinner") }
            if harness.store.lastError != nil { overwrites.append("late attempt published a banner over a newer one") }

            exchangeGate.open()
            await newer.value
            // The control again: the attempt that IS current still publishes.
            // (`lastError` is deliberately not asserted here — whatever the
            // older attempt left is already counted above, once.)
            #expect(harness.store.phase == .authenticating(harness.expectedUser))
            #expect(harness.store.isWorking == false)

            // ── Fence 2: the account is retired underneath a still-newest attempt ──
            //
            // `handleUnauthorized()` is the terminal 401 bridge. It takes no
            // authentication boundary and can fire at any suspension point, so
            // it can retire the session an in-flight attempt began in without
            // ever moving the attempt epoch. Cancellation cannot stand in for
            // this either: the exchange has already returned, it is merely late.
            let retiredGate = Phase09Gate()
            let retired = Phase09AuthHarness(flow: .hostedWebLogin, acceptanceGate: retiredGate)
            let previous = User(id: "user-previous", email: nil, username: nil, displayName: nil, createdAt: nil)
            try? retired.keychain.setString("user-previous", forKey: KeychainKey.userID)
            retired.store.setPhaseForTesting(.authenticated(previous))

            let stale = Task { @MainActor in await retired.complete() }
            let staleIsParked = await phase09Settle { retiredGate.waitingCount == 1 }
            #expect(staleIsParked, "the attempt never reached its exchange")
            _ = await retired.store.handleUnauthorized()
            #expect(retired.store.phase == .unauthenticated, "the 401 bridge did not retire the session")

            retiredGate.open()
            await stale.value
            if retired.store.phase != .unauthenticated {
                overwrites.append("a retired account admitted a late session")
            }

            #expect(!Task.isCancelled)
            #expect(
                overwrites.isEmpty,
                "EXPECTED_RED: a late authentication attempt overwrote newer state"
            )
        }
    }

#endif // !SWIFT_PACKAGE
