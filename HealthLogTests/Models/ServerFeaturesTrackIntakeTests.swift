import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #126 P2 (server v1.42.0, #116 item 18) — `features.trackIntake` on
/// `GET /api/auth/me` lets the add sheet offer "track intake" on an account
/// with no medication yet. Fixture per `AccountPayload.features` in
/// `docs/api/openapi.yaml` on `release/v1.43.0` (`d06ce3604`).
@MainActor
@Suite("features.trackIntake on an empty account (#126 P2)", .serialized, .mockURLSession)
struct ServerFeaturesTrackIntakeTests {
    private nonisolated static let meJSON = #"""
    {"data":{"id":"u1","modules":{},"features":{"trackIntake":true,"cumulativeHourBuckets":true,
      "syncTriggerBackfill":true,"biomarkerMerge":true,"lifeCircumstances":false}},"error":null}
    """#

    private func makeGate(mirror: ServerFeatureMirror) -> ModuleGate {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.3.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return ModuleGate(repo: ModuleGateRepository(api: api), featureMirror: mirror)
    }

    @Test("features decodes beside the module map; a mistyped flag reads false and costs nothing")
    func decodes() throws {
        let me = try #require(try JSONDecoder.hlDefault.decode(APIEnvelope<AuthMeModules>.self, from: Data(Self.meJSON.utf8)).data)
        // One reader: the X4 hourly flags of the same block land here too.
        #expect(
            me.features == ServerFeatures(
                trackIntake: true,
                biomarkerMerge: true,
                cumulativeHourBuckets: true,
                syncTriggerBackfill: true
            )
        )
        let odd = try JSONDecoder.hlDefault.decode(
            AuthMeModules.self,
            from: Data(#"{"modules":{"x":true},"features":{"trackIntake":"yes","biomarkerMerge":true}}"#.utf8)
        )
        #expect(odd.features == ServerFeatures(trackIntake: false, biomarkerMerge: true))
        #expect(odd.modules?["x"] == true)
        let old = try JSONDecoder.hlDefault.decode(AuthMeModules.self, from: Data(#"{"modules":{}}"#.utf8))
        #expect(old.features == nil)
    }

    @Test("On an empty account the switch is offered when the server says it knows trackIntake")
    func emptyAccountOffersSwitch() {
        #expect(Medication.serverKnowsTrackIntake([], features: ServerFeatures(trackIntake: true)))
        #expect(!Medication.serverKnowsTrackIntake([], features: ServerFeatures(trackIntake: false)))
        #expect(!Medication.serverKnowsTrackIntake([], features: nil))
    }

    @Test("ModuleGate.load mirrors features for the model layer; logout clears it")
    func gateMirrorsFeatures() async {
        MockURLProtocol.install { req in
            let body = Data(Self.meJSON.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let mirror = ServerFeatureMirror()
        let gate = makeGate(mirror: mirror)
        await gate.load()
        #expect(gate.serverFeatures?.trackIntake == true)
        #expect(gate.serverFeatures?.biomarkerMerge == true)
        #expect(mirror.current?.trackIntake == true)
        #expect(Medication.serverKnowsTrackIntake([], features: mirror.current))
        gate.clearOnLogout()
        #expect(gate.serverFeatures == nil)
        #expect(mirror.current == nil)
    }

    @Test("INT-Q: one features reader feeds the model layer and the HealthKit upload flags from the same load")
    func oneReaderFeedsBoth() async throws {
        MockURLProtocol.install { req in
            let body = Data(Self.meJSON.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let mirror = ServerFeatureMirror()
        let gate = makeGate(mirror: mirror)
        let defaults = try #require(UserDefaults(suiteName: "test.intq.features.\(UUID().uuidString)"))
        KnownServerVersion.record(ServerVersionInfo(version: "1.43.0"), defaults: defaults)
        nonisolated(unsafe) let unsafeDefaults = defaults
        var sunk: [ServerFeatures?] = []
        gate.serverFeaturesSink = { features in
            sunk.append(features)
            KnownServerVersion.recordFeatures(ServerFeatures.recorded(features), defaults: unsafeDefaults)
        }
        await gate.load()
        #expect(sunk.count == 1)
        #expect(sunk.first == gate.serverFeatures, "the sink gets the very value the gate stores")
        #expect(mirror.current == gate.serverFeatures, "and the model-layer mirror the same")
        #expect(gate.serverFeatures?.cumulativeHourBuckets == true)
        #expect(gate.serverFeatures?.syncTriggerBackfill == true)
        #expect(KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaults))
        #expect(KnownServerVersion.supports(.syncTriggerBackfill, defaults: defaults))
        #expect(ServerFeatures.recorded(ServerFeatures(trackIntake: true, biomarkerMerge: true)).isEmpty)
    }
}
