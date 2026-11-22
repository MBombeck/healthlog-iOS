import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// A throwaway defaults domain per test, so nothing reaches `.standard` and
/// parallel suites never share a key.
@MainActor
private final class VisibilityFixture {
    let suiteName = "medication-visibility-\(UUID().uuidString)"
    let defaults: UserDefaults
    var owner: String? = "user-a"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func makeStore() -> MedicationVisibilityStore {
        MedicationVisibilityStore(defaults: defaults) { [unowned self] in owner }
    }
}

@MainActor
@Suite("Medikamente ausblenden: Speicher")
struct MedicationVisibilityStoreTests {
    @Test("Ausblenden und Einblenden gehen hin und zurück")
    func hideAndUnhideRoundTrip() {
        let fixture = VisibilityFixture()
        let store = fixture.makeStore()

        store.hide("m1")
        store.hide("m2")
        #expect(store.hiddenIDs == ["m1", "m2"])
        #expect(store.isHidden("m1"))

        store.unhide("m1")
        #expect(store.hiddenIDs == ["m2"])
        store.unhide("m2")
        #expect(store.hiddenIDs.isEmpty)
    }

    @Test("Die Auswahl übersteht einen Neuaufbau des Speichers")
    func selectionSurvivesRebuild() {
        let fixture = VisibilityFixture()
        fixture.makeStore().hide("m1")

        let rebuilt = fixture.makeStore()
        #expect(rebuilt.hiddenIDs == ["m1"])
    }

    @Test("Gespeichert werden nur IDs, je Konto unter eigenem Schlüssel")
    func storesOnlyIDsPerAccount() {
        let fixture = VisibilityFixture()
        fixture.makeStore().hide("m1")

        let keys = fixture.defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(MedicationVisibilityStore.keyPrefix) }
        #expect(keys == [MedicationVisibilityStore.keyPrefix + "user-a"])
        #expect(fixture.defaults.stringArray(forKey: keys[0]) == ["m1"])
    }

    @Test("Ein zweites Konto sieht die Auswahl des ersten nie")
    func secondAccountSeesNothing() {
        let fixture = VisibilityFixture()
        let store = fixture.makeStore()
        store.hide("m1")

        // Sign-out, then another account signs in on the same device.
        store.clearOnLogout()
        fixture.owner = "user-b"
        #expect(store.hiddenIDs.isEmpty)
        store.hide("m9")
        #expect(store.hiddenIDs == ["m9"])

        // Back to the first account: its own choice, not the second one's.
        store.clearOnLogout()
        fixture.owner = "user-a"
        #expect(store.hiddenIDs == ["m1"])
    }

    @Test("Ab- und Wiederanmelden desselben Kontos behält die Auswahl")
    func logoutKeepsSelectionForSameAccount() {
        let fixture = VisibilityFixture()
        let store = fixture.makeStore()
        store.hide("m1")

        store.clearOnLogout()
        fixture.owner = nil
        #expect(store.hiddenIDs.isEmpty, "signed out: nothing to show")

        fixture.owner = "user-a"
        #expect(store.hiddenIDs == ["m1"])
    }

    @Test("Zurücksetzen räumt nur die Auswahl des angemeldeten Kontos")
    func wipeClearsOwnAccount() {
        let fixture = VisibilityFixture()
        let store = fixture.makeStore()
        store.hide("m1")
        store.clearOnLogout()
        fixture.owner = "user-b"
        store.hide("m9")

        store.wipeSelection()

        #expect(store.hiddenIDs.isEmpty)
        store.clearOnLogout()
        fixture.owner = "user-a"
        #expect(store.hiddenIDs == ["m1"])
    }

    @Test("Kontolöschung nach dem Schlüsselbund-Wipe räumt das zuletzt aufgelöste Konto")
    func wipeAfterKeychainLossUsesResolvedAccount() {
        let fixture = VisibilityFixture()
        let store = fixture.makeStore()
        store.hide("m1")
        // The account deletion wipes the keychain before the cascade runs.
        fixture.owner = nil

        store.wipeSelection()

        fixture.owner = "user-a"
        let fresh = fixture.makeStore()
        #expect(fresh.hiddenIDs.isEmpty)
    }

    @Test("Ohne auflösbares Konto räumt das Löschen jede Auswahl")
    func wipeWithoutAccountClearsEveryPartition() {
        let fixture = VisibilityFixture()
        fixture.makeStore().hide("m1")
        fixture.owner = "user-b"
        fixture.makeStore().hide("m9")
        fixture.owner = nil

        fixture.makeStore().wipeSelection()

        fixture.owner = "user-a"
        #expect(fixture.makeStore().hiddenIDs.isEmpty)
        fixture.owner = "user-b"
        #expect(fixture.makeStore().hiddenIDs.isEmpty)
    }

    @Test("Ohne Konto wird nichts gespeichert")
    func noAccountStoresNothing() {
        let fixture = VisibilityFixture()
        fixture.owner = nil
        let store = fixture.makeStore()
        store.hide("m1")
        #expect(store.hiddenIDs.isEmpty)
        #expect(fixture.defaults.dictionaryRepresentation().keys.allSatisfy {
            !$0.hasPrefix(MedicationVisibilityStore.keyPrefix)
        })
    }

    @Test("Ausblenden bietet Rückgängig mit dem Namen an, Rückgängig blendet wieder ein")
    func hideOffersUndoWithName() async {
        let fixture = VisibilityFixture()
        let store = fixture.makeStore()
        let undo = UndoCoordinator()
        let medication = medT3Domain(id: "m1", name: "Lisinopril", dose: "10 mg")

        store.hide(medication, undo: undo)

        #expect(store.isHidden("m1"))
        let message = undo.current?.message ?? ""
        #expect(message.contains("Lisinopril"))
        await undo.performUndo()
        #expect(!store.isHidden("m1"))
    }
}

@MainActor
@Suite("Medikamente ausblenden: abgeleitete Listen")
struct MedicationVisibilityListTests {
    private static func makeStore(api: StubAPIClient = StubAPIClient()) throws -> MedicationsStore {
        let outbox = try OutboxQueue(inMemory: true)
        return MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox))
    }

    private static let meds = [
        medT3Domain(id: "a", name: "A", dose: "1 mg"),
        medT3Domain(id: "b", name: "B", dose: "2 mg"),
        medT3Domain(id: "c", name: "C", dose: "3 mg"),
        medT3Domain(id: "x", name: "X", dose: "4 mg", active: false, archivedAt: Date(timeIntervalSince1970: 0))
    ]

    @Test("Sichtbare und ausgeblendete Liste teilen sich die gespeicherte Reihenfolge")
    func listsFollowSavedOrder() throws {
        let store = try Self.makeStore()
        store._testForceSet(medications: Self.meds)
        store.listLayout = MedicationListLayout(order: ["c", "a", "b"])

        #expect(store.visibleActiveMedications(hiding: ["a"]).map(\.id) == ["c", "b"])
        #expect(store.hiddenActiveMedications(hiding: ["a", "c"]).map(\.id) == ["c", "a"])
        #expect(store.visibleActiveMedications(hiding: []).map(\.id) == ["c", "a", "b"])
        #expect(store.hiddenActiveMedications(hiding: []).isEmpty)
    }

    @Test("Ein archiviertes Medikament steht nie unter Ausgeblendet")
    func archivedNeverCountsAsHidden() throws {
        let store = try Self.makeStore()
        store._testForceSet(medications: Self.meds)

        #expect(store.hiddenActiveMedications(hiding: ["x"]).isEmpty)
        #expect(store.archivedMedications.map(\.id) == ["x"])
    }

    @Test("activeMedications und die Badge-Zahl ändern sich durch Ausblenden nicht")
    func activeListAndBadgeUnchanged() throws {
        let store = try Self.makeStore()
        let now = Date()
        // A zone in which `now` is mid-day keeps the pending dose inside today.
        let secondsIntoUTCDay = Int(now.timeIntervalSince1970) % 86400
        var offset = 12 * 3600 - secondsIntoUTCDay
        if offset > 43200 { offset -= 86400 }
        if offset <= -43200 { offset += 86400 }
        let zone = try #require(TimeZone(secondsFromGMT: offset))
        store.profileTimeZoneProvider = { zone }
        store._testForceSet(medications: Self.meds)
        store._testForceSet(todayIntakes: [
            MedicationIntake(
                id: "intake-a",
                medicationId: "a",
                scheduledAt: now.addingTimeInterval(-5 * 60),
                takenAt: nil,
                status: .pending,
                snoozedUntil: nil
            )
        ])
        let fixture = VisibilityFixture()
        let visibility = fixture.makeStore()
        let activeBefore = store.activeMedications.map(\.id)
        let badgeBefore = store.dueOrMissedCount(at: now)

        visibility.hide("a")

        #expect(store.visibleActiveMedications(hiding: visibility.hiddenIDs).map(\.id) == ["b", "c"])
        #expect(store.activeMedications.map(\.id) == activeBefore)
        #expect(badgeBefore == 1)
        #expect(store.dueOrMissedCount(at: now) == badgeBefore)
    }

    @Test("Eine leere oder noch nicht geladene Liste leert die Auswahl nicht")
    func emptyListKeepsSelection() throws {
        let store = try Self.makeStore()
        let fixture = VisibilityFixture()
        let visibility = fixture.makeStore()
        visibility.hide("a")

        store._testForceSet(medications: [])
        #expect(store.hiddenActiveMedications(hiding: visibility.hiddenIDs).isEmpty)
        #expect(visibility.hiddenIDs == ["a"])

        store._testForceSet(medications: Self.meds)
        #expect(store.hiddenActiveMedications(hiding: visibility.hiddenIDs).map(\.id) == ["a"])
    }

    @Test("Archivieren nimmt die ID aus der Auswahl")
    func archiveReleasesID() async throws {
        let api = StubAPIClient()
        await api.setHandler { _ in EmptyResponse() }
        let store = try Self.makeStore(api: api)
        store._testForceSet(medications: Self.meds)
        let fixture = VisibilityFixture()
        let visibility = fixture.makeStore()
        visibility.hide("a")
        visibility.hide("b")

        let outcome = await store.archive(id: "a", releasingFrom: visibility)

        #expect(outcome == .success)
        #expect(visibility.hiddenIDs == ["b"])
        #expect(store.archivedMedications.map(\.id).contains("a"))
    }

    @Test("Wiederherstellen nimmt die ID aus der Auswahl")
    func unarchiveReleasesID() async throws {
        let api = StubAPIClient()
        await api.setHandler { _ in medT3Wire(id: "x", name: "X", dose: "4 mg") }
        let store = try Self.makeStore(api: api)
        store._testForceSet(medications: Self.meds)
        let fixture = VisibilityFixture()
        let visibility = fixture.makeStore()
        visibility.hide("x")

        _ = await store.unarchive(id: "x", releasingFrom: visibility)

        #expect(visibility.hiddenIDs.isEmpty)
        #expect(store.visibleActiveMedications(hiding: visibility.hiddenIDs).map(\.id).contains("x"))
    }
}

@Suite("Medikamente ausblenden: Reihenfolge im Anpassen-Sheet")
struct MedicationVisibilityOrderTests {
    @Test("Ausgeblendete behalten ihren Platz, Sichtbare nehmen die neue Reihenfolge")
    func hiddenKeepSlots() {
        let merged = MedicationVisibilityOrder.merged(
            fullOrder: ["a", "h1", "b", "c", "h2"],
            visibleOrder: ["c", "a", "b"],
            hidden: ["h1", "h2"]
        )
        #expect(merged == ["c", "h1", "a", "b", "h2"])
    }

    @Test("Ohne Ausgeblendete ist das Ergebnis die neue Reihenfolge")
    func noHidden() {
        let merged = MedicationVisibilityOrder.merged(
            fullOrder: ["a", "b", "c"],
            visibleOrder: ["b", "c", "a"],
            hidden: []
        )
        #expect(merged == ["b", "c", "a"])
    }

    @Test("Sind alle ausgeblendet, bleibt die Gesamtreihenfolge")
    func allHidden() {
        let merged = MedicationVisibilityOrder.merged(
            fullOrder: ["a", "b", "c"],
            visibleOrder: [],
            hidden: ["a", "b", "c"]
        )
        #expect(merged == ["a", "b", "c"])
    }

    @Test("Eine unbekannte ID in der Auswahl ändert nichts")
    func unknownHiddenID() {
        let merged = MedicationVisibilityOrder.merged(
            fullOrder: ["a", "h", "b"],
            visibleOrder: ["b", "a"],
            hidden: ["h", "gone"]
        )
        #expect(merged == ["b", "h", "a"])
    }

    @Test("Keine ID der Gesamtreihenfolge geht verloren")
    func noIDLost() {
        let full = ["a", "h", "b", "c"]
        let merged = MedicationVisibilityOrder.merged(fullOrder: full, visibleOrder: ["c"], hidden: ["h"])
        #expect(Set(merged) == Set(full))
        #expect(merged.count == full.count)
        #expect(merged[1] == "h")
    }
}

@Suite("Medikamente ausblenden: Leerzustand und Kontextmenü")
struct MedicationVisibilityScreenDecisionTests {
    @Test("Sind alle aktiven ausgeblendet, erscheint kein Leerzustand")
    func allHiddenOmitsEmptyState() {
        #expect(ActiveMedicationsSection.content(visibleCount: 0, hiddenCount: 2) == .omitted)
        #expect(ActiveMedicationsSection.content(visibleCount: 0, hiddenCount: 0) == .empty)
        #expect(ActiveMedicationsSection.content(visibleCount: 1, hiddenCount: 2) == .cards)
    }

    @Test("Das Kontextmenü lautet Verlauf, Bearbeiten, Ausblenden, Archivieren")
    func contextMenuOrder() {
        let actions = MedicationCardActions.resolve(
            medication: medT3Domain(id: "a", name: "A", dose: "1 mg"),
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(actions.contextMenu == [.history, .edit, .hide, .archive])
    }
}

// swiftlint:enable force_unwrapping
