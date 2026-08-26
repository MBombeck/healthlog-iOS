import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("InMemoryKeychain")
struct InMemoryKeychainTests {
    @Test("set + get round-trip")
    func roundTrip() throws {
        let kc = InMemoryKeychain()
        try kc.setString("hlk_secret", forKey: KeychainKey.authToken)
        #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_secret")
    }

    @Test("remove deletes the entry")
    func remove() throws {
        let kc = InMemoryKeychain()
        try kc.setString("x", forKey: "k")
        try kc.remove(forKey: "k")
        #expect(kc.getString(forKey: "k") == nil)
    }

    @Test("removeAll clears the store")
    func removeAll() throws {
        let kc = InMemoryKeychain()
        try kc.setString("a", forKey: "1")
        try kc.setString("b", forKey: "2")
        try kc.removeAll()
        #expect(kc.getString(forKey: "1") == nil)
        #expect(kc.getString(forKey: "2") == nil)
    }

    @Test("hkAnchor key format is stable")
    func anchorKey() {
        #expect(KeychainKey.hkAnchor(typeIdentifier: "HKBodyMass") == "hk.anchor.HKBodyMass")
    }
}
