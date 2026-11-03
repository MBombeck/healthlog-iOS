// B5 (1.4, from A1) — a connection lost on the wire is not "no network".
//
// `URLError.networkConnectionLost` (-1005) means a load was severed while in
// progress; `.notConnectedToInternet` means nothing could be sent. Up to 1.3
// both became `HLError.offline`, so A1's "sent, unconfirmed" window (S3) never
// saw a dropped connection. `.network(.connectionLost)` existed but was never
// produced. Both still hold a HealthKit page instead of parking it (A2).

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("B5 — networkConnectionLost is its own case", .serialized, .mockURLSession)
    struct NetworkConnectionLostTests {
        private func makeAPI() throws -> APIClient {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_valid_bearer", forKey: KeychainKey.authToken)
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        @Test("the mapping keeps a lost connection apart from no network")
        func mapping() async throws {
            let api = try makeAPI()
            #expect(await api.mapURLError(URLError(.networkConnectionLost)) == .network(.connectionLost))
            #expect(await api.mapURLError(URLError(.notConnectedToInternet)) == .offline)
            #expect(await api.mapURLError(URLError(.timedOut)) == .network(.timeout))
        }

        @Test("a write cut off on the wire throws the lost connection, once")
        func writeThrowsConnectionLost() async throws {
            let api = try makeAPI()
            MockURLProtocol.install { _ in throw URLError(.networkConnectionLost) }
            let request = try APIRequest<EmptyPayload>.post(
                "/api/allergies",
                body: ["name": "Penicillin"],
                maxRetries: 0
            )
            await #expect(throws: HLError.network(.connectionLost)) {
                try await api.sendVoid(request)
            }
        }

        @Test("both stay retriable and queued, and read as connectivity, not as a refusal")
        func classification() {
            let lost = HLError.network(.connectionLost)
            #expect(lost.isRetriable)
            #expect(lost.shouldPersistToOutbox)
            #expect(lost.isTransientConnectivity)
            #expect(HLError.offline.isTransientConnectivity)
            #expect(lost.signInFacingDescription == HLError.offline.signInFacingDescription)
            #expect(EndpointFailureDiagnostics.classify(lost) == .transport)
            #expect(EndpointFailureDiagnostics.classify(HLError.offline) == .offline)
        }

        #if canImport(HealthKit)
            @Test("A2's hold covers a lost connection as well as no network")
            func healthKitPageHolds() {
                #expect(HealthSampleConsumption.isUnreachable(HLError.offline))
                #expect(HealthSampleConsumption.isUnreachable(HLError.network(.connectionLost)))
                #expect(!HealthSampleConsumption.isUnreachable(HLError.network(.timeout)))
            }
        #endif
    }
#endif
