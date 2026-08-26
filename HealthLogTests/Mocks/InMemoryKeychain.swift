import Foundation
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    func setString(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        try setData(data, forKey: key)
    }

    func getString(forKey key: String) -> String? {
        getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setData(_ data: Data, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store[key] = data
    }

    func getData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func remove(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}
