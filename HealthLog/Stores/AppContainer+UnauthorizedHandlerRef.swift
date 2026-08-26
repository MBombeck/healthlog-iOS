import Foundation

/// Mutable Sendable cell that lets the `APIClient` close over an unauthorized-handler
/// reference *before* the `AuthStore` exists. Idempotent: `invokeOnce()` ensures
/// parallel 401-Antworten nur EINMAL den Logout triggern (siehe Audit-Finding #4).
public final class UnauthorizedHandlerRef: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () async -> Void)?
    private var fired: Bool = false

    public init() {}

    public func set(_ handler: @escaping @Sendable () async -> Void) {
        // `withLock` keeps the entire critical section sync — required since Swift 6
        // hides NSLock.lock()/unlock() from async contexts (suspending while holding
        // a lock can deadlock the cooperative thread pool).
        lock.withLock {
            self.handler = handler
            fired = false
        }
    }

    public func invoke() async {
        // Capture the handler under the lock, fire it after release, so the lock
        // never spans a suspension point.
        let h: (@Sendable () async -> Void)? = lock.withLock {
            guard !fired, let h = handler else { return nil }
            fired = true
            return h
        }
        if let h { await h() }
    }

    /// Manuell zurücksetzen, z. B. nach erfolgreichem Re-Login.
    public func reset() {
        lock.withLock {
            fired = false
        }
    }
}
