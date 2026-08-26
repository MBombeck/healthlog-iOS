// Diese Suite haengt am App-Target-only `PasskeyService` (AuthenticationServices
// + UIKit). Im SPM-Library-Build gibt es weder den konkreten Service noch
// `ASPresentationAnchor`, also wird die Datei dort uebersprungen.
#if !SWIFT_PACKAGE && DEBUG

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    #if canImport(UIKit)
        import UIKit
    #endif
    @testable import HealthLog

    // **v0.14.1 (fix/passkey-hang) — Retain-/Release-Buchhaltung des Passkey-Drivers.**
    //
    // Regressionsschutz fuer den "Spinner dreht ewig"-Bug: `ASAuthorizationController`
    // haelt `delegate`/`presentationContextProvider` **weak**. Vor dem Fix hatte der
    // `ASDriver` nach Rueckkehr der `withCheckedThrowingContinuation`-Closure null
    // starke Refs und wurde sofort dealloziert → kein Delegate-Callback, Continuation
    // leakt, `AuthStore.isWorking` haengt fuer immer.
    //
    // Der Test fährt den exakten Wire-/Resolve-Pfad (ohne `performRequests()`, also
    // ohne System-Sheet) und prueft, dass der Service den Driver waehrend des Flows
    // stark haelt und ihn erst **nach** dem Resume wieder freigibt.
    #if canImport(AuthenticationServices) && canImport(UIKit)
        @Suite("Passkey ASDriver retention")
        struct PasskeyDriverRetentionTests {
            @MainActor
            @Test("Driver wird waehrend des Flows gehalten und nach Resolve freigegeben")
            func retainsWhileInFlightReleasesAfterResolve() async {
                let service = PasskeyService()
                #expect(service.activeDriverCount == 0)

                let (whileInFlight, afterResolve) = await service.driverRetentionProbeForTesting()

                // Vor dem Fix waere das 0 gewesen (Driver sofort dealloziert).
                #expect(whileInFlight == 1)
                // Nach jedem Resume-Pfad muss der starke Ref wieder weg sein.
                #expect(afterResolve == 0)
                #expect(service.activeDriverCount == 0)
            }
        }
    #endif

#endif
