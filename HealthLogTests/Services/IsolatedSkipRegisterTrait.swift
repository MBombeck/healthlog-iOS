import Foundation
@testable import HealthLog
import Synchronization
import Testing

/// INT-A — every sync path writes refusals into the ONE skip register
/// (`HealthKitSkippedRowRegister.current`). A suite that drives such a path
/// carries this trait: each test runs against its own in-memory register,
/// never the app's shared file, and reads it back through `.current`.
struct IsolatedSkipRegisterTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let backing = InMemorySkipRegisterFile()
        let register = HealthKitSkippedRowRegister(storage: HealthKitSkippedRowStorage(
            load: { backing.data.withLock { $0 } },
            save: { value in backing.data.withLock { $0 = value } }
        ))
        try await HealthKitSkippedRowRegister.$bound.withValue(register) {
            try await function()
        }
    }
}

extension Trait where Self == IsolatedSkipRegisterTrait {
    /// Binds a fresh in-memory skip register for every test in scope.
    static var isolatedSkipRegister: Self {
        Self()
    }
}

/// The register file of one test, in memory.
private final class InMemorySkipRegisterFile: Sendable {
    let data = Mutex<Data?>(nil)
}
