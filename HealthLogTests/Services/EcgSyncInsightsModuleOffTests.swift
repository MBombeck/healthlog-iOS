import Foundation
@testable import HealthLog
import Testing

/// **Work order #115 · 0.1 — the ECG upload no longer hangs on `insights`.**
///
/// Split from ``EcgSyncCoordinatorTests`` (type-body length). Same fixtures
/// (`EcgSyncTestSupport.swift`), same real ``APIClient`` + `MockURLProtocol`.
///
/// `.serialized` — the suite installs the process-global `MockURLProtocol.handler`.
@Suite("EcgSyncCoordinator — insights-Modul aus (Server v1.39)", .serialized, .mockURLSession)
struct EcgSyncInsightsModuleOffTests {
    /// **Work order #115 · 0.1.** Server v1.39 accepts ECG recordings whatever
    /// the `insights` module says (it means "AI analysis" only), and migration
    /// 0343 switched that module off for every "Hide Coach" account. Build 279
    /// gated the sweep on it, so those accounts' recordings waited behind the
    /// held anchor. Built through the production wiring
    /// (`AppContainer.makeEcgCoordinator`), the sweep must now read from exactly
    /// that held anchor, upload every waiting recording and advance the cursor.
    @Test("insights-Modul aus (v1.39, Migration 0343): der gehaltene Anker lädt die wartenden EKGs hoch")
    @MainActor
    func insightsModuleOffUploadsWaitingRecordings() async {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let registry = AuthenticatedSessionLeaseRegistry()
        registry.activate(ownerID: "user-123")
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.install { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return reply(req)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        defaults().set(true, forKey: EcgHealthSyncStore.prefKey)
        // The cursor 279 held while it refused to sweep.
        let heldAnchor = Data("held-while-insights-off".utf8)
        defaults().set(heldAnchor, forKey: EcgSyncTestSupport.anchorKey)
        // The account after migration 0343: AI analysis off, as `/me` serves it.
        let moduleGate = ModuleGate(modules: ["insights": false, "coach": false])
        #expect(!moduleGate.isEnabled(.insights))
        let source = FakeEcgSource(
            recordings: [
                EcgSyncTestSupport.recording(id: "waiting-1"),
                EcgSyncTestSupport.recording(id: "waiting-2")
            ],
            volts: ["waiting-1": [0.000012], "waiting-2": [-0.000007]],
            nextAnchor: Data("after-upload".utf8)
        )
        let coordinator = AppContainer.makeEcgCoordinator(
            source: source,
            repo: EcgRepository(api: api),
            keychain: keychain,
            authenticatedSessionRegistry: registry,
            defaultsProvider: defaults
        )

        let summary = await coordinator.sync()

        #expect(summary.inserted == 2)
        #expect(recorder.count == 2)
        #expect(source.lastAnchorSeen == heldAnchor, "the sweep must resume from the anchor 279 held")
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Data("after-upload".utf8))
    }
}
