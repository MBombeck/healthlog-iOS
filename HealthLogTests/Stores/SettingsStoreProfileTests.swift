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
        let store = try await makeStore { _ in ProfilePatchResult(profile: updated) }
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
            return ProfilePatchResult(profile: Self.sampleProfile())
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
            if isFirst { return ProfilePatchResult(profile: baseline) }
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

/// #97 / #115 · 0.4 — `PATCH /api/user/profile` answers a PARTIAL save with
/// 200 and `rejectedFields`. Before, iOS decoded only the profile half, so the
/// store returned `true`, the form re-baselined, showed "Saved" and the
/// person's correction was gone without a word.
///
/// The fixture is the v1.39.0 `ProfileUpdateResponse` shape
/// (`docs/api/openapi.yaml`, `rejectedFields: [{ path, code, message }]`,
/// produced by `applyProfileUpdate` → `sanitiseZodIssues`).
@MainActor
@Suite("SettingsStore.updateProfile — partial save (rejectedFields)")
struct SettingsStoreProfileRejectedFieldsTests {
    static let partialEnvelope = #"""
    {"data":{
      "username":"anna","displayName":"Anna-Lena","email":"anna@example.com",
      "dateOfBirth":null,"gender":null,"heightCm":175,"locale":"de","timezone":"Europe/Berlin",
      "timeFormat":"AUTO","dateFormat":"AUTO","moodReminderEnabled":false,
      "fullName":null,"insurerName":null,"insurerIkNumber":null,"hasInsuranceNumber":false,
      "rejectedFields":[
        {"path":"heightCm","code":"too_big","message":"Number must be less than or equal to 300"},
        {"path":"email","code":"rate_limited","message":"Too many email-address changes."}
      ]
    },"error":null}
    """#

    static let cleanEnvelope = #"""
    {"data":{
      "username":"anna","displayName":"Anna-Lena","email":"anna@example.com",
      "dateOfBirth":null,"gender":null,"heightCm":180,"locale":"de","timezone":"Europe/Berlin",
      "timeFormat":"AUTO","dateFormat":"AUTO","moodReminderEnabled":false,
      "fullName":null,"insurerName":null,"insurerIkNumber":null,"hasInsuranceNumber":false
    },"error":null}
    """#

    static func decodeResult(_ json: String) throws -> ProfilePatchResult {
        let envelope = try JSONDecoder.hlDefault.decode(
            APIEnvelope<ProfilePatchResult>.self, from: Data(json.utf8)
        )
        return try #require(envelope.data)
    }

    @Test("The 200 answer decodes both the saved profile and the skipped fields")
    func decodesRejectedFields() throws {
        let result = try Self.decodeResult(Self.partialEnvelope)
        #expect(result.isPartial)
        #expect(result.profile.displayName == "Anna-Lena")
        #expect(result.rejectedFields == [
            ProfileRejectedField(path: "heightCm", code: "too_big", message: "Number must be less than or equal to 300"),
            ProfileRejectedField(path: "email", code: "rate_limited", message: "Too many email-address changes.")
        ])
        #expect(try Self.decodeResult(Self.cleanEnvelope).isPartial == false)
    }

    @Test("A partial save keeps the form open and names each field with its reason")
    func partialSaveKeepsFormOpen() async throws {
        let partial = try Self.decodeResult(Self.partialEnvelope)
        let api = StubAPIClient()
        await api.setHandler { _ in partial }
        let store = try SettingsStore(
            repo: SettingsRepository(api: api),
            defaults: #require(UserDefaults(suiteName: "SettingsStoreProfileRejectedFieldsTests.\(UUID().uuidString)"))
        )

        let ok = await store.updateProfile(
            ProfilePatch(displayName: .some("Anna-Lena"), heightCm: .some(999))
        )

        // `false` is what keeps EditProfileScreen from re-baselining + showing
        // "Saved", and keeps the onboarding step from advancing.
        #expect(ok == false)
        // The sibling that DID land is applied — the server wrote it.
        #expect(store.profile?.displayName == "Anna-Lena")
        #expect(store.error == nil)
        let rejected = store.rejectedProfileFields
        #expect(rejected.map(\.path) == ["heightCm", "email"])
        #expect(rejected.map(\.code) == ["too_big", "rate_limited"])
        // Field + reason, as the notice renders them.
        #expect(rejected.first?.fieldLabel == String(localized: "Height"))
        #expect(rejected.first?.reasonText == String(localized: "profile.rejected.reason.tooBig"))
        #expect(rejected.last?.reasonText == String(localized: "profile.rejected.reason.rateLimited"))
        let line = try #require(rejected.first?.displayLine)
        #expect(line.contains(String(localized: "Height")))
        #expect(line.contains(String(localized: "profile.rejected.reason.tooBig")))
    }

    @Test("The next clean save clears the notice")
    func cleanSaveClearsRejectedFields() async throws {
        let partial = try Self.decodeResult(Self.partialEnvelope)
        let clean = try Self.decodeResult(Self.cleanEnvelope)
        let api = StubAPIClient()
        let queue = ResultQueue([partial, clean])
        await api.setHandler { _ in await queue.next() }
        let store = try SettingsStore(
            repo: SettingsRepository(api: api),
            defaults: #require(UserDefaults(suiteName: "SettingsStoreProfileRejectedFieldsTests.\(UUID().uuidString)"))
        )

        #expect(await store.updateProfile(ProfilePatch(heightCm: .some(999))) == false)
        #expect(store.rejectedProfileFields.isEmpty == false)
        #expect(await store.updateProfile(ProfilePatch(heightCm: .some(180))) == true)
        #expect(store.rejectedProfileFields.isEmpty)
        #expect(store.profile?.heightCm == 180)
    }
}

/// Hands out queued results in order (the last one repeats).
private actor ResultQueue {
    private var results: [ProfilePatchResult]

    init(_ results: [ProfilePatchResult]) {
        self.results = results
    }

    func next() -> ProfilePatchResult {
        results.count > 1 ? results.removeFirst() : results[0]
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
