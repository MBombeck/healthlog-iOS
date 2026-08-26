import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(AuthenticationServices) && canImport(UIKit)

    public final class PasskeyService: NSObject, PasskeyServiceProtocol, @unchecked Sendable {
        /// v0.10.0 (W-Onboarding, Issue 3b) — Watchdog-Timeout. Jeder
        /// `ASAuthorizationController`-Flow rennt gegen diese Schranke; feuert
        /// kein Delegate-Callback (z. B. fensterloser Anchor, dismissed-
        /// without-callback, unbekannter RP), bricht der Timeout den Flow ab
        /// und wirft, statt `isWorking` ewig auf `true` zu lassen.
        ///
        /// v0.11 — von 60 s auf 15 s gesenkt. 60 s sind aus User-Sicht nicht
        /// von "haengt fuer immer" zu unterscheiden — der Spinner dreht eine
        /// gefuehlte Ewigkeit ohne Feedback. Eine Passkey-Assertion, die in
        /// ~15 s kein praesentierbares Credential gezeigt hat (kein passender
        /// Passkey auf dem Geraet, fensterloser Anchor, unbekannter RP), wird
        /// das auch in 60 s nicht tun. Schnell + mit klarer Meldung scheitern
        /// schlaegt langsam + stumm scheitern.
        private static let watchdogTimeout: Duration = .seconds(15)

        /// v0.14.1 (fix/passkey-hang) — Strong owner für die in-flight `ASDriver`s.
        ///
        /// `ASAuthorizationController.delegate` und `.presentationContextProvider`
        /// sind **weak**. Sobald die `withCheckedThrowingContinuation`-Closure in
        /// `assert()`/`register()` zurückkehrt, hätte der lokal erzeugte `driver`
        /// sonst **null** starke Referenzen — ARC würde ihn deallozieren, kaum dass
        /// das System-Sheet erscheint. Dann feuert nie ein Delegate-Callback, der
        /// Watchdog (an den Driver gebunden) stirbt mit, die Continuation leakt und
        /// der Spinner dreht ewig. `PasskeyService` selbst ist ein im `AppContainer`
        /// retainter Singleton; indem wir den Driver hier bis zum Resume halten,
        /// lebt der Flow so lange wie nötig. Keying über `ObjectIdentifier`, weil der
        /// Driver Identity-, nicht Value-Semantik hat. MainActor-isoliert — der ganze
        /// Flow läuft auf dem MainActor, also kein Data-Race auf dem Set.
        @MainActor private var activeDrivers: [ObjectIdentifier: ASDriver] = [:]

        override public init() {
            super.init()
        }

        /// Test-only: Anzahl der aktuell gehaltenen in-flight Driver. Erlaubt einem
        /// Unit-Test, die Retain-/Release-Buchhaltung zu prüfen, ohne den privaten
        /// `ASDriver`-Typ zu exponieren.
        @MainActor var activeDriverCount: Int {
            activeDrivers.count
        }

        #if DEBUG
            /// Test-only Seam für die Retain-/Release-Buchhaltung. Fährt den exakten
            /// Wire-/Resolve-Pfad des echten Flows (`wire` → simulierter Delegate-
            /// Callback) **ohne** `performRequests()`, also ohne System-Sheet.
            ///
            /// - `whileInFlight`: `activeDriverCount`, **nachdem** der Driver verdrahtet
            ///   und die Continuation pending ist, aber **bevor** sie resolved —
            ///   muss `1` sein (genau das, was vor dem Fix fehlte: der Driver wäre
            ///   sonst sofort dealloziert).
            /// - `afterResolve`: `activeDriverCount`, nachdem ein Delegate-Resume-Pfad
            ///   (`didCompleteWithError`) gefeuert und der async Drop-Hop gelaufen
            ///   ist — muss `0` sein.
            @MainActor
            func driverRetentionProbeForTesting() async -> (whileInFlight: Int, afterResolve: Int) {
                // Box, um den Driver aus der Continuation-Closure heraus zu fangen,
                // ohne sie zu resolven.
                final class Box: @unchecked Sendable { var driver: ASDriver? }
                let box = Box()
                let pending = Task { @MainActor in
                    _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<PasskeyAssertion, Error>) in
                        let driver = ASDriver(continuation: .assertion(cont), anchor: ASPresentationAnchor())
                        wire(driver: driver)
                        box.driver = driver
                    }
                }
                // Dem `pending`-Task einen Hop geben, damit sein Body bis zum
                // Continuation-Suspend durchläuft (Driver verdrahtet, count == 1).
                while box.driver == nil {
                    await Task.yield()
                }
                let whileInFlight = activeDrivers.count

                // Throwaway-Controller fürs Delegate-Argument. `ASAuthorizationController`
                // verlangt mind. einen Request (leeres Array crasht), unser Handler nutzt
                // das `controller`-Argument aber gar nicht.
                let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "example.com")
                let throwaway = ASAuthorizationController(
                    authorizationRequests: [provider.createCredentialAssertionRequest(challenge: Data())]
                )
                // Simuliert genau einen Delegate-Callback (Fehler-Pfad) — wie
                // `didCompleteWithError`: resume + teardown + onResolve (Ref-Drop).
                box.driver?.authorizationController(
                    controller: throwaway,
                    didCompleteWithError: HLError.unknown("test-resolve")
                )
                _ = await pending.value
                // Drop läuft asynchron via `Task { @MainActor }` in `onResolve`.
                await Task.yield()
                await Task.yield()
                return (whileInFlight: whileInFlight, afterResolve: activeDrivers.count)
            }
        #endif

        @MainActor
        public func register(
            challenge: String,
            rpId: String,
            rpName: String,
            userID: String,
            userName: String,
            displayName: String,
            anchor: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            guard let challengeData = Data(base64URLEncoded: challenge),
                  let userIDData = Data(base64URLEncoded: userID) ?? userID.data(using: .utf8) else
            {
                throw HLError.unknown("Passkey-Challenge ungültig")
            }
            let resolvedAnchor = anchor.anchor()
            try Self.requirePresentableAnchor(resolvedAnchor)

            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
            let request = provider.createCredentialRegistrationRequest(
                challenge: challengeData,
                name: userName,
                userID: userIDData
            )
            request.displayName = displayName

            return try await withCheckedThrowingContinuation { continuation in
                let driver = ASDriver(continuation: .registration(continuation), anchor: resolvedAnchor)
                start(driver: driver, request: request)
            }
        }

        @MainActor
        public func assert(
            challenge: String,
            rpId: String,
            allowCredentialIDs: [String],
            anchor: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            guard let challengeData = Data(base64URLEncoded: challenge) else {
                throw HLError.unknown("Passkey-Challenge ungültig")
            }
            let resolvedAnchor = anchor.anchor()
            try Self.requirePresentableAnchor(resolvedAnchor)

            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
            let request = provider.createCredentialAssertionRequest(challenge: challengeData)
            request.allowedCredentials = allowCredentialIDs.compactMap {
                Data(base64URLEncoded: $0).map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            }

            return try await withCheckedThrowingContinuation { continuation in
                let driver = ASDriver(continuation: .assertion(continuation), anchor: resolvedAnchor)
                start(driver: driver, request: request)
            }
        }

        /// Gemeinsamer Start-Pfad für `register()` + `assert()`: hält den Driver
        /// stark (im `activeDrivers`-Set) **bevor** `performRequests()` läuft, gibt
        /// ihm ein Release-Closure, das sich selbst aus dem Set entfernt (egal über
        /// welchen Resume-Pfad: Erfolg, Fehler/Cancel oder Watchdog-Timeout), und
        /// startet erst dann den Flow + Watchdog.
        @MainActor
        private func start(driver: ASDriver, request: ASAuthorizationRequest) {
            wire(driver: driver)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = driver
            controller.presentationContextProvider = driver
            driver.retain(controller: controller)
            driver.startWatchdog(timeout: Self.watchdogTimeout)
            controller.performRequests()
        }

        /// Hält den Driver stark (im `activeDrivers`-Set) und verdrahtet sein
        /// `onResolve`-Release-Closure. Aus `start()` **vor** `performRequests()`
        /// aufgerufen, damit der Driver nie ohne starken Ref dasteht. Separat von
        /// `performRequests()` (das ein System-Sheet öffnet), damit die reine
        /// Retain-/Release-Buchhaltung im Unit-Test ohne UI prüfbar ist.
        @MainActor
        private func wire(driver: ASDriver) {
            let key = ObjectIdentifier(driver)
            activeDrivers[key] = driver
            driver.onResolve = { [weak self] in
                // Delegate-Callbacks sind formal non-isoliert; das `activeDrivers`-
                // Set ist MainActor-isoliert. Wir hopen explizit auf den MainActor
                // (kein `assumeIsolated`-Painkiller). Der späte Drop ist unkritisch:
                // bis dahin hält die bereits resolvte Continuation den Flow nicht
                // mehr — wir geben nur den letzten starken Ref auf den Driver frei.
                Task { @MainActor in
                    self?.activeDrivers[key] = nil
                }
            }
        }

        /// v0.10.0 (Issue 3b) — wirft, wenn der aufgeloeste Anchor kein Window
        /// mit `windowScene` ist (d. h. ein fensterloser Fallback-Anchor). Ein
        /// solcher Anchor laesst das System-Sheet ins Leere praesentieren —
        /// es feuert dann ggf. nie einen Delegate-Callback. Lieber sofort
        /// kontrolliert scheitern als ewig haengen.
        @MainActor
        private static func requirePresentableAnchor(_ anchor: ASPresentationAnchor) throws {
            guard anchor.windowScene != nil else {
                throw HLError.unknown("Kein präsentierbares Fenster für die Passkey-Anfrage.")
            }
        }
    }

    private final class ASDriver: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding,
        @unchecked Sendable
    {
        enum Continuation {
            case registration(CheckedContinuation<PasskeyRegistration, Error>)
            case assertion(CheckedContinuation<PasskeyAssertion, Error>)
        }

        private var continuation: Continuation?
        /// Pre-resolved auf `MainActor` durch den Caller. Die Apple-Delegate-Methode
        /// `presentationAnchor(for:)` darf vom System aus jedem Thread aufgerufen
        /// werden — wir können ASN nicht lazily ermitteln.
        private let cachedAnchor: ASPresentationAnchor
        private var retained: ASAuthorizationController?
        /// v0.14.1 (fix/passkey-hang) — vom `PasskeyService` gesetzt; entfernt
        /// diesen Driver aus dem `activeDrivers`-Set des Service. Wird auf **jedem**
        /// Resume-Pfad genau einmal gefeuert (success / error / watchdog), sodass
        /// der Service den starken Ref erst freigibt, **nachdem** der Flow
        /// aufgelöst ist. `@Sendable`, weil es aus den (formal non-isolierten)
        /// Delegate-Callbacks aufgerufen wird; der Service hopt intern auf den
        /// MainActor, bevor er sein `activeDrivers`-Set anfasst. `nil`-bar nur,
        /// weil es nach `init` gesetzt wird.
        var onResolve: (@Sendable () -> Void)?
        /// v0.10.0 (Issue 3b) — Watchdog-Task. Feuert das System keinen
        /// Delegate-Callback (z. B. unbekannter RP, dismissed-without-callback),
        /// resumed dieser Task die Continuation mit einem Timeout-Fehler, damit
        /// `AuthStore.isWorking` nie ewig auf `true` haengt.
        private var watchdog: Task<Void, Never>?

        init(continuation: Continuation, anchor: ASPresentationAnchor) {
            self.continuation = continuation
            cachedAnchor = anchor
        }

        func retain(controller: ASAuthorizationController) {
            retained = controller
        }

        /// Startet den Timeout-Watchdog. Muss auf dem MainActor laufen (der
        /// gesamte Flow ist MainActor-isoliert), damit der Zugriff auf
        /// `continuation` race-frei bleibt.
        @MainActor
        func startWatchdog(timeout: Duration) {
            watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, continuation != nil else { return }
                HLLog.auth.error("Passkey: Watchdog-Timeout — Flow abgebrochen.")
                fail(HLError.unknown(String(
                    localized: "No matching passkey found on this device. Sign in with email, then add a passkey under Settings → Security."
                )))
            }
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            if let reg = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
               case let .registration(cont) = continuation,
               let attestation = reg.rawAttestationObject
            {
                let result = PasskeyRegistration(
                    credentialID: reg.credentialID.base64URLEncodedString(),
                    clientDataJSON: reg.rawClientDataJSON.base64URLEncodedString(),
                    attestationObject: attestation.base64URLEncodedString()
                )
                teardown()
                cont.resume(returning: result)
                return
            }
            if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
               case let .assertion(cont) = continuation
            {
                let result = PasskeyAssertion(
                    credentialID: assertion.credentialID.base64URLEncodedString(),
                    clientDataJSON: assertion.rawClientDataJSON.base64URLEncodedString(),
                    authenticatorData: assertion.rawAuthenticatorData.base64URLEncodedString(),
                    signature: assertion.signature.base64URLEncodedString(),
                    // userHandle ist binary (max 64 byte). Server speichert random bytes, kein UTF-8.
                    // base64url-Encoding ist die WebAuthn-konforme Wire-Form.
                    userHandle: assertion.userID.map { $0.base64URLEncodedString() }
                )
                teardown()
                cont.resume(returning: result)
                return
            }
            fail(HLError.unknown("Unerwartete Passkey-Antwort"))
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            fail(error)
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            cachedAnchor
        }

        /// Resolved den Flow mit einem Fehler. Idempotent über die `continuation`-
        /// `nil`-Guard: ein zweiter `fail`/`teardown` (z. B. Watchdog **und**
        /// Delegate, oder Doppel-Callback) ist ein No-Op — schützt vor
        /// `SWIFT TASK CONTINUATION MISUSE` (Double-Resume).
        private func fail(_ error: Error) {
            guard let cont = continuation else { return }
            teardown()
            switch cont {
            case let .registration(c): c.resume(throwing: error)
            case let .assertion(c): c.resume(throwing: error)
            }
        }

        /// Gemeinsamer Resume-Teardown: cancelt den Watchdog, nullt die
        /// `continuation` (Double-Resume-Guard), gibt den retainten Controller frei
        /// und meldet dem `PasskeyService`, dass dieser Driver aufgelöst ist
        /// (`onResolve`) — letzteres lässt den Service seinen starken Ref **nach**
        /// der Auflösung droppen. Muss **vor** dem `cont.resume(...)` des Callers
        /// laufen, damit `continuation == nil` ist, falls ein zweiter Pfad reinläuft.
        private func teardown() {
            watchdog?.cancel()
            watchdog = nil
            continuation = nil
            retained = nil
            let resolve = onResolve
            onResolve = nil
            resolve?()
        }
    }

    // MARK: - base64url Helpers

    extension Data {
        init?(base64URLEncoded: String) {
            var s = base64URLEncoded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padding = 4 - s.count % 4
            if padding != 4 { s.append(String(repeating: "=", count: padding)) }
            self.init(base64Encoded: s)
        }

        func base64URLEncodedString() -> String {
            base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

#endif

#if !(canImport(AuthenticationServices) && canImport(UIKit))
    /// Fallback for non-iOS-UIKit platforms (e.g. macOS without AppKit-Auth).
    /// Always throws so a host build still compiles.
    public final class StubPasskeyService: PasskeyServiceProtocol, @unchecked Sendable {
        public init() {}
        @MainActor public func register(
            challenge: String, rpId: String, rpName: String,
            userID: String, userName: String, displayName: String,
            anchor: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("Passkeys nicht verfügbar")
        }

        @MainActor public func assert(
            challenge: String, rpId: String, allowCredentialIDs: [String],
            anchor: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("Passkeys nicht verfügbar")
        }
    }
#endif
