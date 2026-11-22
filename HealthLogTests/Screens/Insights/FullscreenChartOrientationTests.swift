// Hosts the full-screen chart in the test scene; the SPM library build has
// no app scene.
#if !SWIFT_PACKAGE && canImport(UIKit)

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// The full-screen chart is the one view the phone may turn for: it
    /// allows landscape while it is up and takes it back when it goes, so the
    /// app stands upright again behind it.
    @MainActor
    @Suite("Full-screen chart orientation", .serialized, .mockURLSession)
    struct FullscreenChartOrientationTests {
        @Test("the cover allows landscape on appear and takes it back on disappear")
        func policySetAndTakenBack() async throws {
            let recorder = OrientationRecorder()
            let store = try Self.makeStore()
            let host = UIHostingController(rootView: AnyView(
                FullscreenChartCover(kind: .weight, store: store, selectedDate: .constant(nil)) { recorder.calls.append($0) }
            ))
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await Self.settle(host)
            #expect(recorder.calls == [true])

            // While it is up, the phone turns, never upside down.
            let up = OrientationPolicy.mask(isPad: false, allowsLandscape: recorder.calls.last ?? false)
            #expect(up == .allButUpsideDown)

            host.rootView = AnyView(Color.clear)
            try await Self.settle(host)
            #expect(recorder.calls == [true, false])

            // Gone, the app stands upright again.
            let after = OrientationPolicy.mask(isPad: false, allowsLandscape: recorder.calls.last ?? true)
            #expect(after == .portrait)
        }

        @Test("the cover stays a full screen cover in every size class")
        func coverHasNoSizing() {
            #expect(HLSheetSizing.resolve(.cover, sizeClass: .compact) == .unset)
            #expect(HLSheetSizing.resolve(.cover, sizeClass: .regular) == .unset)
        }

        // MARK: - Helpers

        static func makeStore() throws -> ChartDetailStore {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.7.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            return try ChartDetailStore(
                kind: .weight,
                measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
                insightsRepo: MetricInsightsRepository(api: api),
                resolveLocale: { "de" }
            )
        }

        static func settle(_ host: UIViewController) async throws {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The cover against the real scene policy. In the serialized
    /// `OrientationPolicyTests` suite, so no other test reads the switch
    /// while the cover holds it.
    extension OrientationPolicyTests {
        @Test("the cover turns the scene policy on and back off", .mockURLSession)
        func fullscreenCoverDrivesTheScenePolicy() async throws {
            guard #available(iOS 27.0, *) else { return }
            #expect(!OrientationPolicy.allowsLandscape)
            defer { OrientationPolicy.allowLandscape(false) }
            let store = try FullscreenChartOrientationTests.makeStore()
            let host = UIHostingController(rootView: AnyView(
                FullscreenChartCover(kind: .weight, store: store, selectedDate: .constant(nil))
            ))
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await FullscreenChartOrientationTests.settle(host)
            #expect(OrientationPolicy.allowsLandscape)
            #expect(OrientationPolicy.mask(isPad: false, allowsLandscape: OrientationPolicy.allowsLandscape) == .allButUpsideDown)

            host.rootView = AnyView(Color.clear)
            try await FullscreenChartOrientationTests.settle(host)
            #expect(!OrientationPolicy.allowsLandscape)
            #expect(OrientationPolicy.mask(isPad: false, allowsLandscape: OrientationPolicy.allowsLandscape) == .portrait)
        }
    }

    @MainActor
    private final class OrientationRecorder {
        var calls: [Bool] = []
    }

#endif
