import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-COACH-CADENCE (#30) — pins the `CoachCadenceSuggestionsStore`:
/// inline `present(_:)` ingest (gated on the opt-in toggle + the dismissed-set),
/// accept creates a reminder (the shared reminders store re-lists), dismiss
/// suppresses + persists (no re-surface), and logout drops the in-memory cards.
/// Uses the shared `StubAPIClient` (defined in `MeasurementsStoreTests.swift`)
/// over the real repository.
@MainActor
@Suite("CoachCadenceSuggestionsStore")
struct CoachCadenceSuggestionsStoreTests {
    /// Isolated UserDefaults so the persisted dismissed-set / opt-in never bleeds
    /// between tests / the real app domain.
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "test.coach.cadence.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return d
    }

    private nonisolated static func suggestion(
        cadenceId: String,
        type: String? = "WEIGHT",
        label: String = "coach.reminderSuggestion.cadence.weightDaily"
    ) -> CoachCadenceSuggestion {
        CoachCadenceSuggestion(
            id: cadenceId,
            cadenceId: cadenceId,
            measurementType: type,
            label: label
        )
    }

    private nonisolated static func reminderRow(id: String, origin: MeasurementReminderRow.Origin) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: id, label: "Reminder \(id)", measurementType: "WEIGHT", intervalDays: 7,
            rrule: nil, endsOn: nil, origin: origin, notifyHour: 8, location: nil,
            nextDueAt: Date(timeIntervalSince1970: 1_800_000_000), lastSatisfiedAt: nil, enabled: true
        )
    }

    private func makeStore(
        api: StubAPIClient,
        defaults: UserDefaults,
        remindersStore: MeasurementRemindersStore? = nil
    ) -> CoachCadenceSuggestionsStore {
        CoachCadenceSuggestionsStore(
            repo: CoachCadenceSuggestionsRepository(api: api),
            remindersStore: remindersStore,
            defaults: defaults
        )
    }

    // MARK: - Ingest (inline coach-turn suggestion) + gating

    @Test("present surfaces an inline suggestion as a card")
    func presentSurfaces() throws {
        let store = try makeStore(api: StubAPIClient(), defaults: isolatedDefaults())

        store.present(Self.suggestion(cadenceId: "weight_daily"))
        store.present(Self.suggestion(cadenceId: "bp_7_2_2"))

        #expect(store.suggestions.map(\.cadenceId) == ["weight_daily", "bp_7_2_2"])
    }

    @Test("present is idempotent per cadenceId (no duplicate cards)")
    func presentDeduplicates() throws {
        let store = try makeStore(api: StubAPIClient(), defaults: isolatedDefaults())

        store.present(Self.suggestion(cadenceId: "weight_daily"))
        store.present(Self.suggestion(cadenceId: "weight_daily"))

        #expect(store.suggestions.map(\.cadenceId) == ["weight_daily"])
    }

    @Test("opt-in toggle OFF → present is a no-op")
    func toggleOffNoPresent() throws {
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: CoachCadenceSuggestionsDefaultsKeys.enabled)
        let store = makeStore(api: StubAPIClient(), defaults: defaults)

        store.present(Self.suggestion(cadenceId: "weight_daily"))

        #expect(store.suggestions.isEmpty, "disabled opt-in keeps the surface empty")
    }

    @Test("Build 9 (9.2) — server mirror OFF wins over a legacy local ON")
    func serverMirrorOffWinsOverLegacyOn() throws {
        let defaults = try isolatedDefaults()
        // Legacy local opt-in ON, but the server mirror says OFF (web opt-out).
        defaults.set(true, forKey: CoachCadenceSuggestionsDefaultsKeys.enabled)
        defaults.set(false, forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
        let store = makeStore(api: StubAPIClient(), defaults: defaults)

        store.present(Self.suggestion(cadenceId: "weight_daily"))

        #expect(store.suggestions.isEmpty, "the server mirror is authoritative when set")
    }

    @Test("Build 9 (9.2) — server mirror ON surfaces even when the legacy key is OFF")
    func serverMirrorOnWinsOverLegacyOff() throws {
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: CoachCadenceSuggestionsDefaultsKeys.enabled)
        defaults.set(true, forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
        let store = makeStore(api: StubAPIClient(), defaults: defaults)

        store.present(Self.suggestion(cadenceId: "weight_daily"))

        #expect(store.suggestions.map(\.cadenceId) == ["weight_daily"])
    }

    @Test("Build 9 (9.2) — with no server mirror, the legacy key is the fallback")
    func legacyFallbackWhenMirrorUnset() throws {
        let defaults = try isolatedDefaults()
        // Mirror never written (Coach never reached) → legacy OFF still suppresses.
        defaults.set(false, forKey: CoachCadenceSuggestionsDefaultsKeys.enabled)
        let store = makeStore(api: StubAPIClient(), defaults: defaults)

        store.present(Self.suggestion(cadenceId: "weight_daily"))

        #expect(store.suggestions.isEmpty)
    }

    @Test("opt-in default ON (never toggled) → present surfaces")
    func defaultOnPresents() throws {
        // No stored value for the opt-in key ⇒ default ON.
        let store = try makeStore(api: StubAPIClient(), defaults: isolatedDefaults())

        store.present(Self.suggestion(cadenceId: "weight_daily"))

        #expect(store.suggestions.map(\.cadenceId) == ["weight_daily"])
    }

    @Test("a locally-dismissed cadence is never re-presented")
    func dismissedCadenceNotRepresented() async throws {
        let defaults = try isolatedDefaults()
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<CoachCadenceSuggestionsRepository.ActionAck> {
                return CoachCadenceSuggestionsRepository.ActionAck()
            }
            throw HLError.unknown("unexpected request \(type(of: req))")
        }
        let store = makeStore(api: api, defaults: defaults)
        let suggestion = Self.suggestion(cadenceId: "weight_daily")
        store.present(suggestion)
        _ = await store.dismiss(suggestion)
        #expect(store.suggestions.isEmpty)

        // The server (or a later coach turn) re-offers the same cadence — it must
        // NOT re-surface locally.
        store.present(suggestion)
        #expect(store.suggestions.isEmpty, "a dismissed cadence stays suppressed")

        // The suppression is persisted: a NEW store on the same defaults still
        // filters it out.
        let store2 = makeStore(api: api, defaults: defaults)
        store2.present(suggestion)
        #expect(store2.suggestions.isEmpty, "the dismissed-set persists across store instances")
    }

    // MARK: - Accept

    @Test("accept POSTs accept + re-lists the reminders so the COACH reminder appears")
    func acceptCreatesReminder() async throws {
        let api = StubAPIClient()
        let actions = LockedActions()
        // The reminders list starts empty; after the accept POST the server has
        // minted a COACH reminder, so the next list returns it.
        await api.setHandler { req in
            if req is APIRequest<CoachCadenceSuggestionsRepository.ActionAck> {
                actions.record("post")
                return CoachCadenceSuggestionsRepository.ActionAck()
            }
            if req is APIRequest<[MeasurementReminderRow]> {
                // After the accept POST, the reminder exists.
                let rows: [MeasurementReminderRow] = actions.contains("post")
                    ? [Self.reminderRow(id: "cr-1", origin: .coach)]
                    : []
                return rows
            }
            throw HLError.unknown("unexpected request \(type(of: req))")
        }
        let remindersStore = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await remindersStore.load() // empty initially
        #expect(remindersStore.reminders.isEmpty)

        let store = try makeStore(api: api, defaults: isolatedDefaults(), remindersStore: remindersStore)
        let suggestion = Self.suggestion(cadenceId: "weight_daily")
        store.present(suggestion)

        let ok = await store.accept(suggestion)

        #expect(ok)
        #expect(actions.contains("post"), "accept must POST the action")
        #expect(store.suggestions.isEmpty, "accepted suggestion is consumed")
        // The shared reminders store re-listed and now holds the server-minted
        // COACH reminder (the app never fabricates the row locally).
        #expect(remindersStore.reminders.map(\.id) == ["cr-1"])
        #expect(remindersStore.reminders.first?.origin == .coach)
    }

    @Test("accept failure restores the card for a retry")
    func acceptFailureRestores() async throws {
        let api = StubAPIClient()
        await api.setHandler { _ in throw HLError.offline }
        let store = try makeStore(api: api, defaults: isolatedDefaults())
        let suggestion = Self.suggestion(cadenceId: "weight_daily")
        store.present(suggestion)

        let ok = await store.accept(suggestion)

        #expect(!ok)
        #expect(store.suggestions.map(\.cadenceId) == ["weight_daily"], "failed accept restores the card")
    }

    // MARK: - Dismiss

    @Test("dismiss drops the card and persists so it never re-surfaces")
    func dismissSuppressesAndPersists() async throws {
        let defaults = try isolatedDefaults()
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<CoachCadenceSuggestionsRepository.ActionAck> { return CoachCadenceSuggestionsRepository.ActionAck() }
            throw HLError.unknown("unexpected request \(type(of: req))")
        }
        let store = makeStore(api: api, defaults: defaults)
        let suggestion = Self.suggestion(cadenceId: "weight_daily")
        store.present(suggestion)

        let ok = await store.dismiss(suggestion)
        #expect(ok)
        #expect(store.suggestions.isEmpty, "dismiss drops the card")

        // A NEW store on the same defaults inherits the persisted suppression.
        let store2 = makeStore(api: api, defaults: defaults)
        store2.present(suggestion)
        #expect(store2.suggestions.isEmpty, "the dismissed-set persists across store instances")
    }

    @Test("dismiss keeps the local suppression even when the POST fails (no nag)")
    func dismissPostFailureStillSuppresses() async throws {
        let api = StubAPIClient()
        await api.setHandler { req in
            if req is APIRequest<CoachCadenceSuggestionsRepository.ActionAck> { throw HLError.offline }
            throw HLError.unknown("unexpected request \(type(of: req))")
        }
        let store = try makeStore(api: api, defaults: isolatedDefaults())
        let suggestion = Self.suggestion(cadenceId: "weight_daily")
        store.present(suggestion)

        let ok = await store.dismiss(suggestion)
        #expect(!ok, "the POST failed")
        #expect(store.suggestions.isEmpty, "but the card is still gone locally")

        // And it never re-surfaces even when re-presented.
        store.present(suggestion)
        #expect(store.suggestions.isEmpty)
    }

    // MARK: - Logout

    @Test("clearOnLogout drops the in-memory suggestions")
    func clearOnLogout() throws {
        let store = try makeStore(api: StubAPIClient(), defaults: isolatedDefaults())
        store.seedForTesting([Self.suggestion(cadenceId: "x")])
        #expect(!store.suggestions.isEmpty)

        store.clearOnLogout()

        #expect(store.suggestions.isEmpty)
    }
}

/// Thread-safe ordered action recorder for the accept-flow sequencing assertion.
private final class LockedActions: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ s: String) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }

    func contains(_ s: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items.contains(s)
    }
}
