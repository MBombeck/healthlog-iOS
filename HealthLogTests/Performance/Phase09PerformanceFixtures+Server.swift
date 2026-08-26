// The render harness below hangs off App-target symbols (`AppContainer`,
// SwiftUI screens, UIKit hosting), none of which exist in the SPM library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import UIKit

    /// **Phase 09 / plan 09-03 — a Keychain that counts instead of asking.**
    ///
    /// The claim 09-03 has to support is "an audited SwiftUI body performs no
    /// Keychain query". A Keychain query is not observable from the outside — it
    /// is a `SecItemCopyMatching` round-trip into the daemon — so the only way to
    /// say anything true about how many a render performs is to put a counting
    /// implementation behind the same protocol the app injects and read the
    /// counter.
    ///
    /// The counter is armable: composing an `AppContainer` legitimately reads the
    /// Keychain many times (server URL, tokens, device id, per-user partitions),
    /// and none of that is a render. ``arm()`` draws the line between composition
    /// and the render being measured.
    final class Phase09CountingKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]
        private var armed = false
        private var recorded: [String] = []

        /// Seed a value without arming the counter — this is fixture setup, not
        /// a read under test.
        func seed(_ value: String, forKey key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = Data(value.utf8)
        }

        /// Start counting. Everything before this — container composition, store
        /// bootstrap — is deliberately not counted.
        func arm() {
            lock.lock()
            defer { lock.unlock() }
            recorded.removeAll()
            armed = true
        }

        /// Stop counting, so a later teardown read cannot inflate the census.
        func disarm() {
            lock.lock()
            defer { lock.unlock() }
            armed = false
        }

        /// Every key read while armed, in order. A list rather than a count: a
        /// census that only says "eight" cannot say *which* query a render made.
        var readsWhileArmed: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var readCountWhileArmed: Int {
            readsWhileArmed.count
        }

        private func note(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            if armed { recorded.append(key) }
        }

        func setString(_ value: String, forKey key: String) throws {
            guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        }

        func getString(forKey key: String) -> String? {
            getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
        }

        func setData(_ data: Data, forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = data
        }

        func getData(forKey key: String) -> Data? {
            note(key)
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func remove(forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            storage.removeValue(forKey: key)
        }

        func removeAll() throws {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll()
        }
    }

    /// Renders a real SwiftUI screen through a real hosting controller, and
    /// answers what the render produced.
    ///
    /// "Zero Keychain reads" is also true of a render that never happened, so the
    /// harness returns the accessibility identifiers it actually painted. A body
    /// that produced the privacy link and read nothing is a different statement
    /// from a body that produced nothing.
    @MainActor
    enum Phase09RenderHarness {
        struct Painted: Sendable {
            /// Every laid-out descendant of the hosting window.
            let viewCount: Int
            /// The rendered pixels. SwiftUI draws most of a screen into shared
            /// layers rather than one `UIView` per row, so the view count cannot
            /// tell "the privacy link was painted" from "it was omitted"; the
            /// pixels can.
            let pixels: Data
        }

        static func render(_ view: some View, size: CGSize = CGSize(width: 393, height: 700)) -> Painted {
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
            let painted = Painted(
                viewCount: descendantCount(of: window),
                pixels: image.pngData() ?? Data()
            )
            window.isHidden = true
            return painted
        }

        private static func descendantCount(of view: UIView) -> Int {
            view.subviews.reduce(1) { $0 + descendantCount(of: $1) }
        }
    }

#endif // !SWIFT_PACKAGE
