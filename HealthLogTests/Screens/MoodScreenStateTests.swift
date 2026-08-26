import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

/// State-contract tests for the v0.4.1 Mood-screen restructure (B3 / M2-A4).
///
/// We snapshot **state**, not pixels, because:
/// - SwiftUI image snapshots are fragile across SDK toolchains
///   (consistent with the rest of the v0.4.x design-system suite).
/// - The reported regressions are state-shaped: Y-axis position, copy
///   reconciliation, accessor correctness.
/// - Pixel snapshots of `MoodScreen` would pull `MoodStore` into a
///   `@MainActor` environment with little extra catch — the renderer's
///   correctness is already covered by `HLEmojiChartContract` (axis
///   position is a Swift Charts API contract, not a runtime calculation).
@MainActor
@Suite("Mood screen state contract")
struct MoodScreenStateTests {
    // MARK: - MoodCopy canonical mapping

    @Test("MoodCopy.scoreLabel — canonical 1..5 mapping")
    func scoreLabelMapping() {
        // v0.6.1.15 Y10 — labels mirror the operator's mood-icon pack
        // (Mood1…Mood5). v0.11 i18n: source keys flipped to EN
        // (Awful/Bad/Ok/Good/Great); the resolved values asserted here are
        // the DE translations from Localizable.xcstrings because the test
        // host runs under the German locale.
        #expect(MoodCopy.scoreLabel(1) == "Lausig")
        #expect(MoodCopy.scoreLabel(2) == "Schlecht")
        #expect(MoodCopy.scoreLabel(3) == "Ok")
        #expect(MoodCopy.scoreLabel(4) == "Gut")
        #expect(MoodCopy.scoreLabel(5) == "Super")
    }

    @Test("MoodCopy.scoreLabel — clamps out-of-range scores")
    func scoreLabelClampsOutOfRange() {
        // A malformed score from a future server-side schema or a buggy
        // optimistic-insert path should not crash the renderer.
        #expect(MoodCopy.scoreLabel(0) == "Lausig")
        #expect(MoodCopy.scoreLabel(-99) == "Lausig")
        #expect(MoodCopy.scoreLabel(99) == "Super")
    }

    @Test("MoodCopy.iconName — canonical 1..5 → PNG-Asset-Pack mapping (v0.14.2)")
    func iconNameMapping() {
        // v0.14.2: die Edit-/Entry-Surfaces zeigen jetzt überall den
        // kanonischen Mood-Icon-Pack (`Assets.xcassets/Mood/Mood1…Mood5`)
        // statt bunter Unicode-Emojis. `MoodCopy.iconName(for:)` ist die
        // einzige Quelle für den Asset-Namen — sowohl der Haupt-Picker
        // (`MoodScreen.iconRow`) als auch `MoodEntryRow` und das
        // `EditMoodSheet` rendern `Image(MoodCopy.iconName(for:))`.
        #expect(MoodCopy.iconName(for: 1) == "Mood1")
        #expect(MoodCopy.iconName(for: 2) == "Mood2")
        #expect(MoodCopy.iconName(for: 3) == "Mood3")
        #expect(MoodCopy.iconName(for: 4) == "Mood4")
        #expect(MoodCopy.iconName(for: 5) == "Mood5")
    }

    @Test("MoodCopy.iconName — clamps out-of-range scores to the scale ends")
    func iconNameClampsOutOfRange() {
        // Out-of-range faellt auf die Endwerte des Picker-Bereichs zurueck,
        // analog zu `scoreLabel` — verhindert einen leeren Glyph-Slot bei
        // beschaedigten Server-Payloads.
        #expect(MoodCopy.iconName(for: 0) == "Mood1")
        #expect(MoodCopy.iconName(for: -99) == "Mood1")
        #expect(MoodCopy.iconName(for: 99) == "Mood5")
    }

    @Test("MoodCopy.iconName — all 5 scores yield distinct asset names")
    func iconNamesAreDistinct() {
        // Jeder Score muss auf einen eigenen Asset-Namen mappen; verhindert
        // ein versehentliches Kollabieren (z.B. zurueck auf einen einzigen
        // Default-Fall) wie beim historischen REG-8-Symptom.
        let names = (1 ... 5).map { MoodCopy.iconName(for: $0) }
        #expect(names.count == 5)
        for name in names {
            #expect(!name.isEmpty)
        }
        #expect(Set(names).count == 5, "Each score must map to a distinct icon asset")
    }

    @Test("MoodCopy.accessibilityLabel — VoiceOver-Sequenz Sehr schlecht…Sehr gut")
    func accessibilityLabelMapping() {
        // Bewusst getrennt vom sichtbaren scoreLabel: VoiceOver liest die
        // Skala eindeutig als "Sehr schlecht" → "Sehr gut", damit Score 3
        // nicht doppeldeutig als "Okay" beim Screen-Reader landet.
        #expect(MoodCopy.accessibilityLabel(for: 1) == "Sehr schlecht")
        #expect(MoodCopy.accessibilityLabel(for: 2) == "Schlecht")
        #expect(MoodCopy.accessibilityLabel(for: 3) == "Neutral")
        #expect(MoodCopy.accessibilityLabel(for: 4) == "Gut")
        #expect(MoodCopy.accessibilityLabel(for: 5) == "Sehr gut")
    }

    @Test("MoodCopy.accessibilityLabel — clamps out-of-range scores")
    func accessibilityLabelClampsOutOfRange() {
        #expect(MoodCopy.accessibilityLabel(for: 0) == "Sehr schlecht")
        #expect(MoodCopy.accessibilityLabel(for: 99) == "Sehr gut")
    }

    // MARK: - MoodEntry.note round-trip (I-3 single-write contract)

    @Test("MoodEntry.note — round-trip via Codable preserves the field")
    func moodEntryNoteRoundTrip() throws {
        // Single-write: ab Server v1.4.30 ist `note` ein dediziertes Feld.
        // Defensive Migration im Init filtert Legacy-Tag-Notes raus —
        // hier verifizieren wir den glatten Pfad.
        let original = MoodEntry(
            id: "n1",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            score: 4,
            tags: ["Sport", "Schlaf"],
            note: "Heute war gut."
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MoodEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.note == "Heute war gut.")
        #expect(decoded.tags == ["Sport", "Schlaf"])
        // Tags-Liste enthält keinen "note:..."-Hack mehr.
        #expect(decoded.tags.allSatisfy { !$0.hasPrefix("note:") })
    }

    @Test("MoodEntry — legacy tags note hack migriert in dediziertes Feld")
    func moodEntryLegacyNoteMigration() {
        // Backfill-Pfad: alte Server-Antworten (vor v1.4.30) lieferten
        // Notizen via "note:..." Tag. Das Model filtert diese im Init
        // automatisch in `note` um.
        let legacy = MoodEntry(
            id: "leg1",
            mood: .good,
            tags: ["Sport", "note:Alte Notiz", "Schlaf"],
            moodLoggedAt: .now,
            source: "MANUAL"
        )
        #expect(legacy.note == "Alte Notiz")
        #expect(legacy.tags == ["Sport", "Schlaf"])
    }

    @Test("MoodEntryPatch — note ist ein dediziertes Feld")
    func moodEntryPatchHasNoteField() throws {
        let patch = MoodEntryPatch(score: 3, tags: ["Sport"], recordedAt: nil, note: "hi")
        let encoder = JSONEncoder()
        let data = try encoder.encode(patch)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["note"] as? String == "hi")
        // Single-write: tags enthält keinen note-Hack.
        let tags = try #require(json["tags"] as? [String])
        #expect(tags == ["Sport"])
    }

    // MARK: - Manual free-text tags

    @Test("Manual tags trim and deduplicate case-insensitively")
    func manualTagsTrimAndDedupe() {
        var tags = ["Reisen"]
        #expect(MoodFreeTextTagRules.insert("  Familie  ", into: &tags) == .inserted)
        #expect(MoodFreeTextTagRules.insert(" reisen ", into: &tags) == .duplicate)
        #expect(tags == ["Reisen", "Familie"])
    }

    @Test("Manual tags enforce the 20 tag and 50 character wire limits")
    func manualTagLimits() {
        var tags = (0 ..< MoodFreeTextTagRules.maximumCount - 1).map { "Tag \($0)" }
        #expect(MoodFreeTextTagRules.insert(String(repeating: "x", count: 50), into: &tags) == .inserted)
        #expect(MoodFreeTextTagRules.insert("one too many", into: &tags) == .tooMany)
        #expect(tags.count == 20)

        var empty: [String] = []
        #expect(MoodFreeTextTagRules.insert("", into: &empty) == .empty)
        #expect(
            MoodFreeTextTagRules.insert(String(repeating: "x", count: 51), into: &empty)
                == .tooLong
        )
        #expect(empty.isEmpty)
    }

    // MARK: - MoodTrendChart contract (line-chart Y-range + ref-lines)

    @Test("MoodTrendChart.Entry — gibt Y-Werte im 1...5-Range zurück")
    func moodTrendChartEntries() {
        let now = Date()
        let entries: [MoodTrendChart.Entry] = (1 ... 5).map {
            MoodTrendChart.Entry(date: now.addingTimeInterval(Double($0) * 86400), score: $0)
        }
        #expect(entries.count == 5)
        #expect(entries.map(\.score) == [1, 2, 3, 4, 5])
        // Reference-Lines bei 1/3/5 müssen im Y-Domain [0.5...5.5] liegen.
        for refLine in [1, 3, 5] {
            #expect((0.5 ... 5.5).contains(Double(refLine)))
        }
    }

    // v0.11 — the `HLEmojiChart.Entry` snapshot test was retired alongside the
    // rival `HLEmojiChart` mood chart (AUDIT-FINAL §H3). The canonical mood
    // trend chart is now `MoodTrendChart` (richer 3-layer anatomy); there is no
    // second mood-chart entry type to pin.

    // MARK: - MoodStore derived accessors (B3 §2)

    @Test("MoodStore.todayEntry — returns today's most-recent entry")
    func todayEntryReturnsToday() throws {
        let store = try makeStore()
        store.replaceEntriesForTesting([
            sample(id: "today", score: 4, ago: 0),
            sample(id: "yesterday", score: 3, ago: 86400)
        ])
        let today = store.todayEntry()
        #expect(today?.id == "today")
        #expect(today?.score == 4)
    }

    @Test("MoodStore.todayEntry — nil when no entry today")
    func todayEntryNilWhenNotLogged() throws {
        let store = try makeStore()
        store.replaceEntriesForTesting([
            sample(id: "yesterday", score: 3, ago: 86400)
        ])
        #expect(store.todayEntry() == nil)
    }

    @Test("MoodStore.recents — defensive sort + prefix")
    func recentsPrefix() throws {
        let store = try makeStore()
        store.replaceEntriesForTesting([
            sample(id: "old", score: 2, ago: 10 * 86400),
            sample(id: "newest", score: 5, ago: 0),
            sample(id: "mid", score: 3, ago: 86400)
        ])
        let recents = store.recents(limit: 2)
        #expect(recents.count == 2)
        // Newest-first independent of input order.
        #expect(recents[0].id == "newest")
        #expect(recents[1].id == "mid")
    }

    @Test("MoodStore.recents — clamps negative limit to 0")
    func recentsClampsNegative() throws {
        let store = try makeStore()
        store.replaceEntriesForTesting([
            sample(id: "x", score: 3, ago: 0)
        ])
        #expect(store.recents(limit: -5).isEmpty)
    }

    @Test("MoodStore.totalCount — matches entries array")
    func totalCountMatchesEntries() throws {
        let store = try makeStore()
        store.replaceEntriesForTesting([
            sample(id: "a", score: 3, ago: 0),
            sample(id: "b", score: 4, ago: 86400),
            sample(id: "c", score: 5, ago: 2 * 86400)
        ])
        #expect(store.totalCount == 3)
    }

    // MARK: - TestPushVariant contract (B3 §3, narrowed by R1 streak removal)

    @Test("TestPushVariant — two variants with distinct categoryIdentifiers")
    func pushVariantContract() {
        // v0.5.0+ R1 dropped the `streakReminder` variant alongside the rest
        // of the 366-day streak feature. The diagnose menu now offers two
        // shapes (standard + moodReminder).
        let variants = TestPushVariant.allCases
        #expect(variants.count == 2)
        let ids = Set(variants.map(\.categoryIdentifier))
        #expect(ids == ["TEST", "MOOD_REMINDER"])
        // Each variant must produce a non-empty title + body so the
        // notification renders something useful in the banner.
        for v in variants {
            #expect(!v.title.isEmpty)
            #expect(!v.body.isEmpty)
            #expect(!v.menuTitle.isEmpty)
        }
    }

    @Test("TestPushVariant.standard — preserves the legacy copy")
    func standardVariantPreservesLegacyCopy() {
        let v = TestPushVariant.standard
        #expect(v.title == "HealthLog — Test")
        #expect(v.body == "Wenn du das siehst, funktionieren deine Benachrichtigungen.")
        #expect(v.categoryIdentifier == "TEST")
    }

    // MARK: - Helpers

    private func sample(id: String, score: Int, ago seconds: TimeInterval) -> MoodEntry {
        MoodEntry(
            id: id,
            recordedAt: Date().addingTimeInterval(-seconds),
            score: score
        )
    }

    /// Constructs a real `MoodStore` wrapping an in-memory outbox + stub
    /// APIClient. We never call `load()` / `log()` from this test suite —
    /// the goal is to exercise derived accessors after explicit
    /// `replaceEntriesForTesting(...)` injection.
    private func makeStore() throws -> MoodStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)
        return MoodStore(repo: repo)
    }
}
