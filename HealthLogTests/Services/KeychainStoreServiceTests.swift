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
