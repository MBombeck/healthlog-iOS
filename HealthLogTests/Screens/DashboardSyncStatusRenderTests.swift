// App-Target-Symbole (`DashboardSyncAvatar`, `DashboardSyncStatusPanel`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **U1 (#16) — die neue Sync-Anzeige oben im Dashboard, gerendert.**
    ///
    /// Hostet Glyph-Platz und Statusfeld in einem echten `UIWindow`
    /// (das Test-Bundle läuft in der App) und prüft, dass in den erwarteten
    /// Bereichen etwas gezeichnet wird. Mit `SYNCACT_RENDER_DIR=/tmp/…` werden
    /// die Bilder zusätzlich exportiert — nie in den Checkout; so entstehen die
    /// Bilder im U1- und im INT-L-Bericht.
    @MainActor
    @Suite("U1 — Dashboard-Sync-Anzeige: Render-Prüfung", .serialized, .mockURLSession)
    struct DashboardSyncStatusRenderTests {
        private static let syncBody = Data(#"""
        {"data":{"userId":"usr_u1","timezone":"Europe/Berlin",
          "lastSyncedAt":"2026-10-04T08:00:00Z","serverNow":"2026-10-04T08:00:01Z",
          "measurements":{"lastUpdatedAt":"2026-10-04T08:00:00Z","liveCount":1,"tombstonedCount":0}
        },"error":null}
        """#.utf8)

        private func makeStore(
            diagnostics: HKSyncDiagnostics? = nil,
            minimumSyncingHold: Duration = .zero
        ) -> SyncStateStore {
            let env = AppEnvironment(
                // swiftlint:disable:next force_unwrapping
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.1.1",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            return SyncStateStore(
                repo: SyncStateRepository(api: api),
                minimumSyncingHold: minimumSyncingHold,
                doneHold: .seconds(60),
                healthDiagnostics: diagnostics
            )
        }

        private func stub(status: Int) {
            let success = Self.syncBody
            MockURLProtocol.install { req in
                let body = status == 200 ? success : Data()
                // swiftlint:disable:next force_unwrapping
                return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
            }
        }

        /// A stand-in for `DashboardHeader`'s row: greeting left, the real sync
        /// cluster right, the real panel below when `showsPanel`.
        private func header(store: SyncStateStore, showsPanel: Bool) -> some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HStack(alignment: .center, spacing: HLSpace.md) {
                        VStack(alignment: .leading, spacing: HLSpace.xs) {
                            Text(verbatim: "Hi, Alex").font(.hlLargeTitle).foregroundStyle(HLText.primary)
                            Text(verbatim: "Samstag, 4. Oktober").font(.hlSubhead).foregroundStyle(HLText.secondary)
                        }
                        Spacer(minLength: HLSpace.sm)
                        DashboardSyncAvatar(showProfile: .constant(false), showsSyncStatus: .constant(showsPanel)) {
                            HLProfileAvatar(size: 44, email: nil, initials: "MB")
                        }
                    }
                    if showsPanel {
                        DashboardSyncStatusPanel {}
                    }
                    Spacer()
                }
                .padding(HLSpace.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(HLSurface.primary)
            }
            .environment(store)
        }

        private func render(_ view: some View, name: String, dark: Bool) throws -> UIImage {
            let size = CGSize(width: 393, height: 420)
            let host = UIHostingController(rootView: AnyView(view))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window.windowScene = scene
            }
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["SYNCACT_RENDER_DIR"] {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let suffix = dark ? "dark" : "light"
                try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
            }
            window.isHidden = true
            return image
        }

        /// Contrast inside a rectangle ⇒ something painted there.
        private func hasInk(_ image: UIImage, in rect: CGRect) -> Bool {
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
                return false
            }
            let scale = CGFloat(cg.width) / image.size.width
            let x0 = max(0, Int(rect.minX * scale)), x1 = min(cg.width, Int(rect.maxX * scale))
            let y0 = max(0, Int(rect.minY * scale)), y1 = min(cg.height, Int(rect.maxY * scale))
            let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
            var minLum = 255, maxLum = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    let p = y * bpr + x * bpp
                    let lum = (Int(ptr[p]) + Int(ptr[p + 1]) + Int(ptr[p + 2])) / 3
                    minLum = min(minLum, lum)
                    maxLum = max(maxLum, lum)
                }
            }
            return maxLum - minLum > 25
        }

        /// Largest luminance spread inside a rectangle (every pixel).
        private func luminanceSpread(_ image: UIImage, in rect: CGRect) -> Int {
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
                return Int.max
            }
            let scale = CGFloat(cg.width) / image.size.width
            let x0 = max(0, Int(rect.minX * scale)), x1 = min(cg.width, Int(rect.maxX * scale))
            let y0 = max(0, Int(rect.minY * scale)), y1 = min(cg.height, Int(rect.maxY * scale))
            let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
            var minLum = 255, maxLum = 0
            for y in y0 ..< y1 {
                for x in x0 ..< x1 {
                    let p = y * bpr + x * bpp
                    let lum = (Int(ptr[p]) + Int(ptr[p + 1]) + Int(ptr[p + 2])) / 3
                    minLum = min(minLum, lum)
                    maxLum = max(maxLum, lum)
                }
            }
            return maxLum - minLum
        }

        /// U5 (1.1.1) — the strip just inside the panel's top edge, above its
        /// first text line. On the glass surface the header's date line
        /// ("Samstag, 4. Oktober") refracted into exactly this strip as a faint
        /// ghost (spread 5 light, 22 dark); the opaque fill keeps it flat.
        private let panelTopEdge = CGRect(x: 34, y: 155.5, width: 130, height: 4.5)

        /// The glyph sits left of the 44 pt avatar (x ≈ 333…377), below the
        /// navigation bar's safe area (row centre y ≈ 110).
        private let glyphRect = CGRect(x: 286, y: 90, width: 42, height: 44)
        private let panelRect = CGRect(x: 24, y: 160, width: 345, height: 110)

        @Test("Ruhend und gesund: kein Glyph", arguments: [false, true])
        func idleShowsNothing(dark: Bool) throws {
            let image = try render(header(store: makeStore(), showsPanel: false), name: "01-idle", dark: dark)
            #expect(!hasInk(image, in: glyphRect))
        }

        @Test("Während des Syncs dreht der Glyph", arguments: [false, true])
        func syncingShowsGlyph(dark: Bool) async throws {
            let store = makeStore(minimumSyncingHold: .seconds(3))
            stub(status: 200)
            let handshake = Task { await store.handshake() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.indicatorGlyph == .syncing)
            let image = try render(header(store: store, showsPanel: false), name: "02-syncing", dark: dark)
            #expect(hasInk(image, in: glyphRect))
            await handshake.value
        }

        @Test("Nach dem Sync steht das Häkchen", arguments: [false, true])
        func doneShowsCheckmark(dark: Bool) async throws {
            let store = makeStore()
            stub(status: 200)
            await store.handshake()
            #expect(store.indicatorGlyph == .done)
            let image = try render(header(store: store, showsPanel: false), name: "03-done", dark: dark)
            #expect(hasInk(image, in: glyphRect))
        }

        private func diagnostics(acceptedAgo seconds: TimeInterval, channel: SyncChannel) throws -> (HKSyncDiagnostics, () -> Void) {
            let suite = "intl.render.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let diagnostics = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            diagnostics.noteServerAcceptance(at: Date().addingTimeInterval(-seconds), channel: channel)
            return (diagnostics, { defaults.removePersistentDomain(forName: suite) })
        }

        // INT-L (1.1.1) — no badge on the avatar; each attention state is a
        // calm glyph in the slot next to it, and the panel reads as plain text.

        @Test("Fehlgeschlagen: eigenes Symbol im Platz neben dem Avatar", arguments: [false, true])
        func failedShowsAttentionGlyph(dark: Bool) async throws {
            let store = makeStore()
            stub(status: 500)
            await store.handshake()
            #expect(store.slotGlyph() == .attention(.failed))
            let image = try render(header(store: store, showsPanel: false), name: "04-attention-failed", dark: dark)
            #expect(hasInk(image, in: glyphRect))
        }

        @Test("Verlorene Einträge: eigenes Symbol", arguments: [false, true])
        func lostWritesShowAttentionGlyph(dark: Bool) throws {
            let store = makeStore()
            store.noteDeadLettered(2)
            #expect(store.slotGlyph() == .attention(.failedWrites(2)))
            let image = try render(header(store: store, showsPanel: false), name: "05-attention-lost", dark: dark)
            #expect(hasInk(image, in: glyphRect))
        }

        /// The waiting state needs ten real seconds (`SyncAttention.queuedAfter`),
        /// so one test renders both appearances.
        @Test("Wartende Einträge: eigenes Symbol, erst nach zehn Sekunden")
        func queuedShowsAttentionGlyph() async throws {
            let store = makeStore()
            store.noteOutboxPending(3)
            #expect(store.slotGlyph() == nil, "a fresh save does not blink")
            try await Task.sleep(for: .seconds(SyncAttention.queuedAfter + 0.5))
            #expect(store.slotGlyph() == .attention(.queued(3)))
            for dark in [false, true] {
                let image = try render(header(store: store, showsPanel: false), name: "06-attention-queued", dark: dark)
                #expect(hasInk(image, in: glyphRect))
            }
        }

        @Test("Länger als einen Tag nichts: eigenes Symbol", arguments: [false, true])
        func staleShowsAttentionGlyph(dark: Bool) throws {
            let (diagnostics, cleanup) = try diagnostics(acceptedAgo: 2 * 86400, channel: .background)
            defer { cleanup() }
            let store = makeStore(diagnostics: diagnostics)
            guard case .attention(.stale) = store.slotGlyph() else {
                Issue.record("expected the stale glyph, got \(String(describing: store.slotGlyph()))")
                return
            }
            let image = try render(header(store: store, showsPanel: false), name: "07-attention-stale", dark: dark)
            #expect(hasInk(image, in: glyphRect))
        }

        @Test("Statusfeld, gesund: nur die letzte Zeit mit Kanal und der Diagnose-Link", arguments: [false, true])
        func healthyPanel(dark: Bool) throws {
            let (diagnostics, cleanup) = try diagnostics(acceptedAgo: 7 * 60, channel: .background)
            defer { cleanup() }
            let store = makeStore(diagnostics: diagnostics)
            #expect(store.slotGlyph() == nil)
            #expect(store.lastSync?.channel == .background)
            let image = try render(header(store: store, showsPanel: true), name: "08-panel-healthy", dark: dark)
            #expect(!hasInk(image, in: glyphRect))
            #expect(hasInk(image, in: panelRect))
            #expect(luminanceSpread(image, in: panelTopEdge) <= 2, "the panel must not mirror the header behind it")
        }

        @Test("Statusfeld nach einem Fehler: Satz, Zeit mit Kanal, Diagnose-Link", arguments: [false, true])
        func failedPanel(dark: Bool) async throws {
            let (diagnostics, cleanup) = try diagnostics(acceptedAgo: 7 * 60, channel: .background)
            defer { cleanup() }
            let store = makeStore(diagnostics: diagnostics)
            stub(status: 500)
            await store.handshake()
            #expect(store.attention() == .failed)
            #expect(store.lastSync?.channel == .background)
            let image = try render(header(store: store, showsPanel: true), name: "09-panel-failed", dark: dark)
            #expect(hasInk(image, in: glyphRect))
            #expect(hasInk(image, in: panelRect))
            #expect(luminanceSpread(image, in: panelTopEdge) <= 2, "the panel must not mirror the header behind it")
        }
    }
#endif
