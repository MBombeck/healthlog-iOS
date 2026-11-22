import Foundation

/// **1.7 — the freshness check's deadline.** Returns `nil` when the work fails
/// or takes longer than `seconds`; the late request is cancelled.
enum MedicationFreshnessDeadline {
    static let seconds: TimeInterval = 5

    /// `GET /api/sync/state` within ``seconds``.
    static func handshake(_ repository: SyncStateRepository) async -> ServerSyncStateDTO? {
        await run(seconds: seconds) { try await repository.handshake() }
    }

    static func run<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first: T? = await group.next().flatMap(\.self)
            group.cancelAll()
            return first
        }
    }
}
