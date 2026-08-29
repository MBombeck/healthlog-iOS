import Foundation
@testable import HealthLog
import Testing

/// **25-03 (GH #1) — completeness derived from what exists on the account.**
///
/// The first community report (public issue #1): a profile created in the web
/// UI, then an iOS sign-in — and the app walked the full setup flow anyway.
/// Mechanism, verified in the server source rather than inferred: iOS reads
/// the module-TOUR flag `onboardingTourCompleted` as account-setup
/// completion, but the web wizard's own completion is a different column
/// (`onboardingCompletedAt`, set on step 4), and `GET /api/auth/me` serves
/// both — alongside the account substance itself (`heightCm`, `dateOfBirth`,
/// `gender`). A web-created account therefore answers `incomplete` today, and
/// resolver rule 1 ("a server answer wins outright") correctly routes that
/// answer into the full flow. The defect is the answer, not the rule.
///
/// Every case here drives the real store through the real repository decode
/// of a verbatim `/me` row, so the suite measures what production would do
/// with the reporter's account — not what a hand-built enum value would do.
@MainActor
@Suite("Account setup completeness — GH #1")
struct AccountSetupCompletenessTests {
    // MARK: - The /me rows, verbatim in shape

    /// The reporter's account: web wizard completed (`onboardingCompletedAt`
    /// set, the baseline profile written), the module coachmark tour never
    /// taken (`onboardingTourCompleted: false`). No health value of any real
    /// person appears here — the substance values are invented.
    private static let reporterRow = """
    {
      "id": "web-created",
      "username": "reporter",
      "onboardingTourCompleted": false,
      "onboardingCompletedAt": "2026-08-20T10:00:00.000Z",
      "heightCm": 172,
      "dateOfBirth": "1994-03-12T00:00:00.000Z",
      "gender": "FEMALE"
    }
    """

    /// Profile substance alone — the public reply's literal derivation: what
    /// exists on the account, with neither marker set.
    private static let substanceOnlyRow = """
    {
      "id": "web-created",
      "onboardingTourCompleted": false,
      "heightCm": 181,
      "dateOfBirth": "1988-11-02T00:00:00.000Z",
      "gender": "MALE"
    }
    """

    /// The web wizard's completion record alone — a user who skipped the
    /// baseline profile inside the wizard still finished the wizard.
    private static let recordOnlyRow = """
    {
      "id": "web-created",
      "onboardingTourCompleted": false,
      "onboardingCompletedAt": "2026-08-20T10:00:00.000Z"
    }
    """

    /// A genuinely new account: the marker answers `false` and nothing else
    /// on the row says otherwise.
    private static let newAccountRow = """
    {
      "id": "brand-new",
      "onboardingTourCompleted": false
    }
    """

    /// Explicit nulls are the server saying "not recorded" — the same amount
    /// of evidence as an absent key, which is none.
    private static let nullSubstanceRow = """
    {
      "id": "brand-new",
      "onboardingTourCompleted": false,
      "onboardingCompletedAt": null,
      "heightCm": null,
      "dateOfBirth": null,
      "gender": ""
    }
    """

    /// The marker fast path: `true` needs no substance to stand.
    private static let markerOnlyRow = """
    {
      "id": "app-created",
      "onboardingTourCompleted": true
    }
    """

    // MARK: - RED: the reporter's state

    @Test("the reporter's account — web-created, fully set up, fresh device — is handed to the shell, owing the device-local head only")
    func webWizardCompletedAccountReachesTheShell() async throws {
        let store = try await Self.settled(row: Self.reporterRow)
        var violations: [String] = []
        if store.resolution != .completed {
            violations.append("classified \(String(describing: store.resolution)) instead of completed")
        }
        if !store.isCompleted {
            violations.append("isCompleted is false for a fully-set-up account")
        }
        let route = PostAuthenticationRouteResolver.resolve(
            server: store.resolution ?? .unavailable,
            cache: store.evidence
        )
        if route != .authenticatedShell {
            violations.append("routed to \(route.rawValue) instead of the shell")
        }
        // The device-local half is untouched by this plan and still owed on a
        // fresh handset — the reporter SHOULD see HealthKit + notifications.
        let scope = PostAuthenticationRouteResolver.setupScope(
            accountSetupComplete: route == .authenticatedShell,
            deviceLocalSetup: .outstanding
        )
        if route == .authenticatedShell, scope != .deviceLocalOnly {
            violations.append("a fresh device skipped its own local head")
        }
        #expect(violations.isEmpty, "EXPECTED_RED: 25-03 GH1 web-created account replayed the account-level setup")
    }

    @Test("profile substance alone derives completion — what exists on the account outranks a marker nobody set")
    func profileSubstanceAloneDerivesCompletion() async throws {
        let store = try await Self.settled(row: Self.substanceOnlyRow)
        var violations: [String] = []
        if store.resolution != .completed {
            violations.append("classified \(String(describing: store.resolution)) instead of completed")
        }
        if !store.isCompleted {
            violations.append("isCompleted is false despite account substance")
        }
        #expect(violations.isEmpty, "EXPECTED_RED: 25-03 GH1 profile substance did not derive completion")
    }

    @Test("the web wizard's own completion record counts, even with the baseline profile skipped")
    func webWizardCompletionRecordCounts() async throws {
        let store = try await Self.settled(row: Self.recordOnlyRow)
        var violations: [String] = []
        if store.resolution != .completed {
            violations.append("classified \(String(describing: store.resolution)) instead of completed")
        }
        if !store.isCompleted {
            violations.append("isCompleted is false despite the account's completion record")
        }
        #expect(violations.isEmpty, "EXPECTED_RED: 25-03 GH1 the web wizard's completion record was ignored")
    }

    // MARK: - Controls (green from construction, in both worlds)

    @Test("a genuinely new account still walks the full flow — the guard must not over-correct")
    func genuinelyNewAccountStillWalksTheFullFlow() async throws {
        let store = try await Self.settled(row: Self.newAccountRow)
        #expect(store.resolution == .incomplete)
        #expect(store.isCompleted == false)
        let route = PostAuthenticationRouteResolver.resolve(server: .incomplete, cache: store.evidence)
        #expect(route == .setup)
        #expect(PostAuthenticationRouteResolver.setupScope(
            accountSetupComplete: false,
            deviceLocalSetup: .outstanding
        ) == .full)
    }

    @Test("explicit nulls are absent evidence, not substance")
    func explicitNullsAreAbsentEvidence() async throws {
        let store = try await Self.settled(row: Self.nullSubstanceRow)
        #expect(store.resolution == .incomplete)
        #expect(store.isCompleted == false)
    }

    @Test("the marker fast path stands on its own — no substance required")
    func markerFastPathNeedsNoSubstance() async throws {
        let store = try await Self.settled(row: Self.markerOnlyRow)
        #expect(store.resolution == .completed)
        #expect(store.isCompleted == true)
    }

    /// The stated could-not-determine fallback, pinned from the reporter's
    /// exact position: fresh device, no same-account cache, and the lookup
    /// fails. The answer is the retry surface — never the full flow, and
    /// never the shell.
    @Test("a failed lookup on a fresh device retries instead of replaying setup")
    func failedLookupOnAFreshDeviceRetries() async throws {
        let api = StubAPIClient()
        api.sendHandler = { _ in throw HLError.unknown("offline") }
        let defaults = try Self.isolatedDefaults()
        let store = OnboardingTourStore(repo: OnboardingTourRepository(api: api), defaults: defaults)
        await store.refresh(owner: Self.owner)
        #expect(store.resolution == .unavailable)
        #expect(store.isCompleted == false)
        let route = PostAuthenticationRouteResolver.resolve(server: .unavailable, cache: store.evidence)
        #expect(route == .retryCompletionLookup)
        #expect(route != .setup, "ambiguity must never replay the wizard")
    }

    // MARK: - Pins (post-GREEN): the classification is total and one-directional

    private struct ClassificationRow {
        let marker: Bool?
        let record: Bool
        let substance: Bool
        let answer: PostAuthenticationRouteInput.ServerCompletion
    }

    /// Every marker state against every evidence shape — 12 cells, one answer
    /// each. Written out rather than re-derived, so a change to the rule has
    /// to change this table and say why.
    private static let classificationMatrix: [ClassificationRow] = [
        // A true marker completes, whatever the evidence says — the fast path.
        ClassificationRow(marker: true, record: false, substance: false, answer: .completed),
        ClassificationRow(marker: true, record: false, substance: true, answer: .completed),
        ClassificationRow(marker: true, record: true, substance: false, answer: .completed),
        ClassificationRow(marker: true, record: true, substance: true, answer: .completed),
        // Account evidence completes over a false marker (GH #1) …
        ClassificationRow(marker: false, record: false, substance: true, answer: .completed),
        ClassificationRow(marker: false, record: true, substance: false, answer: .completed),
        ClassificationRow(marker: false, record: true, substance: true, answer: .completed),
        // … and over an absent one (an older deployment with a set-up account).
        ClassificationRow(marker: nil, record: false, substance: true, answer: .completed),
        ClassificationRow(marker: nil, record: true, substance: false, answer: .completed),
        ClassificationRow(marker: nil, record: true, substance: true, answer: .completed),
        // The one genuinely-new-account cell.
        ClassificationRow(marker: false, record: false, substance: false, answer: .incomplete),
        // No marker field, no evidence: pre-v1.18.6 semantics, cache may stand in.
        ClassificationRow(marker: nil, record: false, substance: false, answer: .endpointAbsent)
    ]

    @Test("the classification matrix is total, widens only toward completed, and never invents an answer")
    func classificationMatrixIsTotal() {
        #expect(Self.classificationMatrix.count == 12, "3 marker states × 2 record × 2 substance")
        for row in Self.classificationMatrix {
            let answer = OnboardingTourStore.classifySetupCompletion(AuthMeOnboarding(
                onboardingTourCompleted: row.marker,
                hasSetupCompletionRecord: row.record,
                hasProfileSubstance: row.substance
            ))
            #expect(
                answer == row.answer,
                "marker \(String(describing: row.marker)) / record \(row.record) / substance \(row.substance)"
            )
            #expect(answer != .unavailable, "classification never answers for a lookup that did not resolve")
        }
        let incomplete = Self.classificationMatrix.filter { $0.answer == .incomplete }
        #expect(incomplete.count == 1, "incomplete requires the marker to say so AND the row to show nothing")
        #expect(incomplete.first?.marker == false)
        let absent = Self.classificationMatrix.filter { $0.answer == .endpointAbsent }
        #expect(absent.count == 1, "endpointAbsent is reachable only with no marker field and no evidence")
    }

    @Test("the decode finds evidence only where the wire actually carries it")
    func decodeFindsEvidenceOnlyWhereCarried() throws {
        let reporter = try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: Data(Self.reporterRow.utf8))
        #expect(reporter.onboardingTourCompleted == false)
        #expect(reporter.hasSetupCompletionRecord == true)
        #expect(reporter.hasProfileSubstance == true)

        let fresh = try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: Data(Self.newAccountRow.utf8))
        #expect(fresh.hasSetupCompletionRecord == false)
        #expect(fresh.hasProfileSubstance == false)

        let nulled = try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: Data(Self.nullSubstanceRow.utf8))
        #expect(nulled.hasSetupCompletionRecord == false, "an explicit null is not a record")
        #expect(nulled.hasProfileSubstance == false, "explicit nulls and an empty gender are not substance")

        // A single substance field suffices, and an unreadable representation
        // degrades to absence rather than a throw.
        let heightOnly = try JSONDecoder.hlDefault.decode(
            AuthMeOnboarding.self,
            from: Data(#"{"onboardingTourCompleted": false, "heightCm": 172}"#.utf8)
        )
        #expect(heightOnly.hasProfileSubstance == true)
    }

    // MARK: - Helpers

    private static let owner = PostAuthenticationRouteInput.Owner(id: "gh1-owner", generation: 1)

    /// Fresh device, no cache: decode the verbatim `/me` row through the same
    /// projection the repository requests, refresh, and hand back the settled
    /// store.
    private static func settled(row: String) async throws -> OnboardingTourStore {
        let api = StubAPIClient()
        api.sendHandler = { _ in
            try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: Data(row.utf8))
        }
        let store = try OnboardingTourStore(repo: OnboardingTourRepository(api: api), defaults: isolatedDefaults())
        await store.refresh(owner: owner)
        return store
    }

    private static func isolatedDefaults() throws -> UserDefaults {
        let suite = "test.accountSetupCompleteness.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Handler-based stub mirroring `OnboardingTourStoreTests.StubAPIClient`.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch — got \(type(of: result)), expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }
}
