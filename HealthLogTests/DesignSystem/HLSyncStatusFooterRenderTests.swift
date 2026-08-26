// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// v0.14.8 W2-SYNCUX — render verification for the sync-status rollout.
    ///
    /// The W2-SYNCUX wave mounts `HLSyncStatusFooter` in three host shapes
    /// (ScrollView stack-child, `List`/`Form` empty-section footer) and pins
    /// `HLSyncBanner` for the first-login indicator. These tests render each
    /// host inside a real `UIWindow` (the test bundle is app-hosted) with a
    /// settled `SyncStateStore` and assert the caption actually paints —
    /// catching the class of bug where a `Section {} footer:` arrangement
    /// silently drops the footer in a particular container.
    ///
    /// Set `SYNCUX_RENDER_DIR=/tmp/syncux` to additionally export the
    /// rendered PNGs for visual review (used by the W2-SYNCUX report).
    @MainActor
    @Suite("HLSyncStatusFooter / HLSyncBanner — render verification", .serialized)
    struct HLSyncStatusFooterRenderTests {
        // MARK: - Fixtures

        /// A `SyncStateStore` whose handshake has landed → the footer's
        /// settled "Zuletzt synchronisiert HH:MM" arm renders.
        private func makeSettledStore() async throws -> SyncStateStore {
            let env = AppEnvironment(
                // swiftlint:disable:next force_unwrapping
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.14.8",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            // b178 W-SYNCVIS — zero phase holds + idle-settle below, so the
            // fixture renders the SETTLED caption, not the transient .done beat.
            let store = SyncStateStore(
                repo: SyncStateRepository(api: api),
                minimumSyncingHold: .zero,
                doneHold: .zero
            )
            MockURLProtocol.handler = { req in
                let body = Data(#"""
                {"data":{
                  "userId":"usr_render","timezone":"Europe/Berlin",
                  "lastSyncedAt":"2026-06-11T08:00:00Z",
                  "serverNow":"2026-06-11T08:00:01Z",
                  "measurements":{"lastUpdatedAt":"2026-06-11T08:00:00Z","liveCount":1,"tombstonedCount":0}
                },"error":null}
                """#.utf8)
                // swiftlint:disable:next force_unwrapping
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            await store.handshake()
            #expect(store.lastHandshakeAt != nil, "fixture handshake must settle the store")
            // Wait out the (zero-hold) .done beat so the phase is .idle.
            let deadline = ContinuousClock.now + .seconds(3)
            while store.phase != .idle, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.phase == .idle, "fixture phase must settle to .idle")
            return store
        }

        /// Hosts `view` in a key window, lets layout settle, renders a PNG,
        /// returns the image. Exports to `$SYNCUX_RENDER_DIR/<name>.png`
        /// when the env var is present.
        private func render(_ view: some View, name: String) throws -> UIImage {
            let size = CGSize(width: 393, height: 600)
            let host = UIHostingController(rootView: AnyView(view))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            // A detached window renders blank — attach it to the host app's
            // scene (the test bundle is app-hosted, so a scene exists).
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            {
                window.windowScene = scene
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // Run-loop spins — List/Form (collection-view backed) need a
            // pass beyond layoutIfNeeded to realize rows + section footers.
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["SYNCUX_RENDER_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        /// `true` when the image carries non-background pixels in the given
        /// vertical band (cheap "did anything paint here" probe).
        private func hasInk(_ image: UIImage, fromY: CGFloat, toY: CGFloat) -> Bool {
            guard let cg = image.cgImage else { return false }
            let width = cg.width
            let height = cg.height
            let y0 = max(0, Int(fromY / image.size.height * CGFloat(height)))
            let y1 = min(height, Int(toY / image.size.height * CGFloat(height)))
            guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return false }
            let bpr = cg.bytesPerRow
            let bpp = cg.bitsPerPixel / 8
            var minLum = 255
            var maxLum = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: 0, to: width, by: 4) {
                    let p = y * bpr + x * bpp
                    let lum = (Int(ptr[p]) + Int(ptr[p + 1]) + Int(ptr[p + 2])) / 3
                    minLum = min(minLum, lum)
                    maxLum = max(maxLum, lum)
                }
            }
            // Contrast in the band ⇒ something painted (text on background).
            return (maxLum - minLum) > 25
        }

        // MARK: - Tests

        @Test("ScrollView host — settled caption paints under the content")
        func scrollViewFooterPaints() async throws {
            let store = try await makeSettledStore()
            let view = ScrollView {
                VStack(spacing: HLSpace.lg) {
                    Text(verbatim: "Content")
                    HLSyncStatusFooter()
                }
                .frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .environment(store)
            let image = try render(view, name: "unit-scroll-footer")
            #expect(hasInk(image, fromY: 30, toY: 90), "caption band under the content must paint")
        }

        @Test("List host — empty-section footer renders the caption")
        func listSectionFooterPaints() async throws {
            let store = try await makeSettledStore()
            let view = List {
                Section { Text(verbatim: "Row") }
                Section {} footer: {
                    HLSyncStatusFooter()
                }
            }
            .listStyle(.insetGrouped)
            .environment(store)
            let image = try render(view, name: "unit-list-footer")
            // insetGrouped: row card ends ≈ y=100; the footer caption paints
            // in the band below it.
            #expect(hasInk(image, fromY: 100, toY: 200), "List Section-footer caption must paint")
        }

        @Test("Form host — empty-section footer renders the caption")
        func formSectionFooterPaints() async throws {
            let store = try await makeSettledStore()
            let view = Form {
                Section { Text(verbatim: "Row") }
                Section {} footer: {
                    HLSyncStatusFooter()
                }
            }
            .environment(store)
            let image = try render(view, name: "unit-form-footer")
            #expect(hasInk(image, fromY: 100, toY: 200), "Form Section-footer caption must paint")
        }

        @Test("HLSyncBanner — spinner + done states paint")
        func syncBannerStatesPaint() throws {
            let view = VStack(spacing: HLSpace.lg) {
                HLSyncBanner(text: String(localized: "sync.status.preparing"), showsSpinner: true)
                HLSyncBanner(text: String(localized: "sync.banner.done"), symbol: "checkmark.circle.fill")
            }
            .frame(maxWidth: .infinity)
            .background(Color.black)
            let image = try render(view, name: "unit-sync-banner")
            #expect(
                hasInk(image, fromY: 0, toY: image.size.height),
                "banner strips must paint"
            ) // VStack zentriert im 600pt-Frame — volle Hoehe pruefen
        }
    }
#endif
