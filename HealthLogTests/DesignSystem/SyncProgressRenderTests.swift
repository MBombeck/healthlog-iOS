// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// b177 W-SYNCPROGRESS — render verification for the three quantity-bearing
    /// caption states the wave adds to `SyncStatusCaption`:
    ///
    /// 1. **syncing-count** — in flight with outstanding work
    ///    ("Wird synchronisiert… N ausstehend"),
    /// 2. **queued** — settled with an offline backlog ("N ausstehend"),
    /// 3. **transmitted** — the short post-drain beat ("Daten übermittelt ✓").
    ///
    /// Set `SYNCPROG_RENDER_DIR=/tmp/syncprog` to export the rendered PNGs for
    /// visual review (used by the W-SYNCPROGRESS report).
    @MainActor
    @Suite("SyncStatusCaption — sync-progress render verification", .serialized)
    struct SyncProgressRenderTests {
        // MARK: - Fixtures

        /// A `SyncStateStore` whose handshake has landed — the queued /
        /// transmitted arms are handshake-gated (self-suppression contract).
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
            // fixture renders the SETTLED arms, not the transient .done beat.
            let store = SyncStateStore(
                repo: SyncStateRepository(api: api),
                drainConfirmationHold: .seconds(30),
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

        /// Hosts `view` in a key window, lets layout settle, renders a PNG.
        /// Exports to `$SYNCPROG_RENDER_DIR/<name>.png` when the env var is set.
        private func render(_ view: some View, name: String) throws -> UIImage {
            let size = CGSize(width: 393, height: 240)
            let host = UIHostingController(rootView: AnyView(view))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            {
                window.windowScene = scene
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["SYNCPROG_RENDER_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        /// `true` when the image carries contrast in the given vertical band.
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
            return (maxLum - minLum) > 25
        }

        private func host(_ store: SyncStateStore, screenLoading: Bool) -> some View {
            VStack(spacing: HLSpace.lg) {
                Text(verbatim: "Content")
                HLSyncStatusFooter(screenLoading: screenLoading)
            }
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .environment(store)
        }

        // MARK: - Tests

        @Test("state 1 — in flight with count paints the quantity line")
        func syncingCountPaints() async throws {
            let store = try await makeSettledStore()
            store.noteOutboxPending(3)
            store.noteActiveRevalidations(20)
            #expect(store.pendingSyncCount == 23)
            let image = try render(host(store, screenLoading: true), name: "syncprog-1-syncing-count")
            #expect(hasInk(image, fromY: 150, toY: 225), "syncing-count caption must paint")
        }

        @Test("state 2 — settled offline backlog paints the queued line")
        func queuedPaints() async throws {
            let store = try await makeSettledStore()
            store.noteOutboxPending(4)
            let image = try render(host(store, screenLoading: false), name: "syncprog-2-queued")
            #expect(hasInk(image, fromY: 150, toY: 225), "queued caption must paint")
        }

        @Test("state 3 — post-drain transmitted beat paints")
        func transmittedPaints() async throws {
            let store = try await makeSettledStore()
            store.noteOutboxPending(2)
            store.noteOutboxPending(0)
            #expect(store.showsDrainConfirmation)
            let image = try render(host(store, screenLoading: false), name: "syncprog-3-transmitted")
            #expect(hasInk(image, fromY: 150, toY: 225), "transmitted caption must paint")
        }
    }
#endif
