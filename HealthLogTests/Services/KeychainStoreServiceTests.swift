import Foundation
@testable import HealthLog
import Testing

/// Config-style pin (passes as soon as the constant exists — this is the one
/// case where a structural pin is acceptable, because the failure it guards
/// against only manifests in an extension process, which the unit host cannot
/// impersonate). The widget extension's `Bundle.main.bundleIdentifier` is
/// `dev.healthlog.app.widgets`; `kSecAttrService` is part of the keychain
/// primary key, so a service derived from the bundle id makes every widget
/// intent read an empty keychain (no bearer, no server URL, no cipher key).
@Suite("KeychainStore — one service for app and extensions")
struct KeychainStoreServiceTests {
    @Test("default service is the fixed app service, never the caller's bundle id")
    func defaultServiceIsAppService() {
        #expect(KeychainStore().service == KeychainStore.appService)
        #expect(KeychainStore.appService == "dev.healthlog.app")
    }
}

/// D5 #7 — overwriting an item must never make it look missing to a reader
/// in between. A delete-then-add upsert opened that window on every token
/// refresh; an in-place update has none.
@Suite("KeychainStore — an overwrite is never seen as missing", .serialized)
struct KeychainStoreAtomicWriteTests {
    @Test("a reader running alongside 300 overwrites never finds the item missing")
    func overwriteNeverLooksMissing() async throws {
        let store = KeychainStore(service: "dev.healthlog.tests.atomic.\(UUID().uuidString)")
        defer { try? store.removeAll() }
        try store.setString("v0", forKey: "token")
        try #require(store.getString(forKey: "token") == "v0")

        let reader = Task.detached { () -> Int in
            var misses = 0
            for _ in 0 ..< 3000 {
                if case .missing = store.readData(forKey: "token") { misses += 1 }
            }
            return misses
        }
        for round in 1 ... 300 {
            try store.setString("v\(round)", forKey: "token")
        }
        let misses = await reader.value
        #expect(misses == 0, "a concurrent reader saw no token \(misses) times")
        #expect(store.getString(forKey: "token") == "v300")
    }

    @Test("the first write of a key still adds it")
    func firstWriteAdds() throws {
        let store = KeychainStore(service: "dev.healthlog.tests.atomic.\(UUID().uuidString)")
        defer { try? store.removeAll() }
        #expect(store.readData(forKey: "fresh") == .missing)
        try store.setString("a", forKey: "fresh")
        #expect(store.getString(forKey: "fresh") == "a")
    }
}
