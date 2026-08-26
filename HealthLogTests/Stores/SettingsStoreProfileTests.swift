import Foundation
@testable import HealthLog
import Testing

/// Locks the SettingsStore profile-update path added in v0.4.1 / M2-A6:
///
/// - `updateProfile(_:)` sends only the diff fields over the wire
///   (via `SettingsRepository.patchProfile`)
/// - returns `true` on success and updates the in-memory `profile`
///   with the server's response
/// - returns `false` and surfaces `error` on failure, without mutating
///   the existing profile snapshot
/// - early-returns `true` when the patch is empty (no-op)
@MainActor
@Suite("SettingsStore.updateProfile")
struct SettingsStoreProfileTests {
    private func makeStore(handler: @escaping @Sendable (any Sendable) async throws -> any Sendable)
        async throws -> SettingsStore
    {
        let api = StubAPIClient()
        await api.setHandler(handler)
        let repo = SettingsRepository(api: api)
        // Pass an isolated UserDefaults so the test does not contaminate
        // the host's settings store with biometric/tint/unit prefs.
        let suiteName = "SettingsStoreProfileTests.\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: suiteName),
            "isolated UserDefaults suite must be constructible"
        )
        return SettingsStore(repo: repo, defaults: defaults)
    }

    private nonisolated static func sampleProfile(displayName: String = "Anna") -> UserProfile {
        UserProfile(
            username: "anna",
            displayName: displayName,
            email: "anna@example.com",
            dateOfBirth: nil,
            gender: nil,
            heightCm: 175,
            locale: "de",
            timezone: "Europe/Berlin"
        )
    }

    @Test("Successful patch updates the profile snapshot")
    func successUpdatesProfile() async throws {
        let updated = Self.sampleProfile(displayName: "Anna-Lena")
        let store = try await makeStore { _ in updated }
        let patch = ProfilePatch(displayName: .some("Anna-Lena"))

        let ok = await store.updateProfile(patch)
        #expect(ok == true)
        #expect(store.profile?.displayName == "Anna-Lena")
        #expect(store.error == nil)
    }

    @Test("Empty patch is a no-op and returns true without firing the API")
    func emptyPatchNoOp() async throws {
        let store = try await makeStore { _ in
            Issue.record("API should not be called for empty patch")
            return Self.sampleProfile()
        }
        let ok = await store.updateProfile(ProfilePatch())
        #expect(ok == true)
        #expect(store.profile == nil) // never loaded; still nil
        #expect(store.error == nil)
    }

    @Test("Failure surfaces error and returns false")
    func failureSurfacesError() async throws {
        let store = try await makeStore { _ in
            throw HLError.server(status: 400, code: nil, message: "Validation failed")
        }
        let ok = await store.updateProfile(ProfilePatch(heightCm: .some(999)))
        #expect(ok == false)
        if case let .server(status, _, _) = store.error {
            #expect(status == 400)
        } else {
            Issue.record("Expected .server error, got \(String(describing: store.error))")
        }
    }

    @Test("Failure does not clobber an existing profile snapshot")
    func failurePreservesProfile() async throws {
        // Seed the store via a successful patch first.
        let baseline = Self.sampleProfile(displayName: "Anna")
        let api = StubAPIClient()
        // First call returns baseline; second call throws.
        let counter = AsyncCounter()
        await api.setHandler { _ in
            let isFirst = await counter.next()
            if isFirst { return baseline }
            throw HLError.offline
        }
        let repo = SettingsRepository(api: api)
        let suiteName = "SettingsStoreProfileTests.\(UUID().uuidString)"
        let store = try SettingsStore(repo: repo, defaults: #require(UserDefaults(suiteName: suiteName)))

        let okSeed = await store.updateProfile(ProfilePatch(displayName: .some("Anna")))
        #expect(okSeed == true)
        #expect(store.profile?.displayName == "Anna")

        let okFail = await store.updateProfile(ProfilePatch(displayName: .some("X")))
        #expect(okFail == false)
        // Snapshot survives.
        #expect(store.profile?.displayName == "Anna")
        #expect(store.error == .offline)
    }
}

/// Tiny actor used by `failurePreservesProfile` to flip a flag between
/// the seed call and the failing follow-up. Swift 6 strict concurrency
/// rules forbid mutable captures of a `var Bool` inside `@Sendable`
/// closures, so we wrap the flip in an actor.
private actor AsyncCounter {
    private var calls = 0
    func next() -> Bool {
        calls += 1
        return calls == 1
    }
}
