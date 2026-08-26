import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Die Einheit hängt an diesem Suite.**
///
/// Der Server faltet nachts rohe Puls-Zeilen und ignoriert `stats:`-Zeilen. Ein
/// UTC-Tag, der beide Formen trägt, wird doppelt gezählt. ``HRUploadModeSchedule``
/// ist die eine Funktion, die beide Hochlade-Pfade fragen — der Einzel-Batch in
/// `HealthLogStandard` verwirft eine `heartRate`-Probe genau dann, wenn sie
/// `.buckets` sagt, und der Faltungs-Sweep gibt eine Faltung genau dann aus,
/// wenn sie `.buckets` sagt.
///
/// Geprüft wird deshalb nicht „der Schalter schaltet", sondern:
///
/// 1. Umschalten wirkt **nur** an einer UTC-Mitternacht — in beide Richtungen.
/// 2. Innerhalb eines UTC-Tages ist die Antwort **konstant**, also entsteht pro
///    Tag genau eine der beiden Formen.
/// 3. Bereits abgelaufene Stufen bleiben stehen; die Vergangenheit wird nie
///    umgeschrieben.
///
/// Kein `.serialized` nötig: jeder Test bekommt eine eigene `UserDefaults`-Suite
/// und eine feste `now`, es gibt keinen prozessweiten Zustand.
@Suite("HRUploadModeSchedule — Umschalten nur an der UTC-Tagesgrenze")
struct HRUploadModeScheduleTests {
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.hruploadmode.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter.fractional.date(from: iso)!
    }

    private let user = "u1"

    // MARK: - Grundlage: ohne Schalter gilt weiter der scharfgestellte Stichtag

    @Test("ohne Umschaltung entscheidet der Stichtag: davor roh, ab dann Faltungen")
    func fallsBackToTheArmedCutover() {
        let defaults = isolatedDefaults()
        let now = date("2026-06-21T14:00:00.000Z") // Stichtag → 2026-06-22T00:00Z

        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-21T23:59:59.000Z"), userId: user, now: now, defaults: defaults
            ) == .raw
        )
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-22T00:00:00.000Z"), userId: user, now: now, defaults: defaults
            ) == .buckets
        )
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-07-01T09:00:00.000Z"), userId: user, now: now, defaults: defaults
            ) == .buckets
        )
    }

    // MARK: - Hinweg: Faltungen → roh

    @Test("Umschalten auf roh wirkt erst ab der nächsten UTC-Mitternacht — der laufende Tag bleibt Faltung")
    func switchToRawTakesEffectAtNextUTCMidnight() throws {
        let defaults = isolatedDefaults()
        // Stichtag scharfstellen, danach mitten in einem Faltungs-Tag umschalten.
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        let tapped = date("2026-06-25T14:37:10.000Z")

        let change = try #require(
            HRUploadModeSchedule.setDesiredMode(.raw, userId: user, now: tapped, defaults: defaults)
        )
        #expect(change.effectiveFrom == date("2026-06-26T00:00:00.000Z"))
        #expect(change.mode == .raw)

        // Der ganze Tipp-Tag bleibt Faltung — er trägt bereits abgeschlossene
        // Faltungen, Rohwerte daneben wären die Doppelzählung.
        for hour in ["00:00", "14:37", "23:59"] {
            #expect(
                HRUploadModeSchedule.mode(
                    at: date("2026-06-25T\(hour):00.000Z"), userId: user, now: tapped, defaults: defaults
                ) == .buckets
            )
        }
        // Ab der Tagesgrenze roh.
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-26T00:00:00.000Z"), userId: user, now: tapped, defaults: defaults
            ) == .raw
        )
        // Und der laufende Zustand ist bis dahin unverändert.
        #expect(HRUploadModeSchedule.currentMode(userId: user, now: tapped, defaults: defaults) == .buckets)
    }

    // MARK: - Rückweg: roh → Faltungen

    @Test("Zurückschalten auf Faltungen wirkt ebenfalls erst ab der nächsten UTC-Mitternacht")
    func switchBackToBucketsTakesEffectAtNextUTCMidnight() throws {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: user, now: date("2026-06-25T14:37:10.000Z"), defaults: defaults
        )

        let back = date("2026-06-28T08:05:00.000Z")
        let change = try #require(
            HRUploadModeSchedule.setDesiredMode(.buckets, userId: user, now: back, defaults: defaults)
        )
        #expect(change.effectiveFrom == date("2026-06-29T00:00:00.000Z"))

        // Der dazwischenliegende Tag trägt NICHT beides: 28.06. bleibt komplett roh.
        for hour in ["00:00", "08:05", "23:59"] {
            #expect(
                HRUploadModeSchedule.mode(
                    at: date("2026-06-28T\(hour):00.000Z"), userId: user, now: back, defaults: defaults
                ) == .raw
            )
        }
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-29T00:00:00.000Z"), userId: user, now: back, defaults: defaults
            ) == .buckets
        )
    }

    // MARK: - Die Kern-Invariante

    @Test("kein UTC-Tag trägt beide Formen — über beide Umschaltrichtungen und jede Tagesgrenze hinweg")
    func noUTCDayCarriesBothForms() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        // Hin, zurück, und noch einmal hin — inklusive eines Tipps direkt auf
        // einer UTC-Mitternacht und eines kurz davor.
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: user, now: date("2026-06-25T14:37:10.000Z"), defaults: defaults
        )
        HRUploadModeSchedule.setDesiredMode(
            .buckets, userId: user, now: date("2026-06-28T00:00:00.000Z"), defaults: defaults
        )
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: user, now: date("2026-07-02T23:59:59.000Z"), defaults: defaults
        )
        let now = date("2026-07-06T12:00:00.000Z")

        let calendar = HRBucketCutoverStore.utcCalendar
        var modesPerDay: [Date: Set<HRUploadMode>] = [:]
        // Jede Stunde von zwei Tagen vor dem Stichtag bis eine Woche nach der
        // letzten Umschaltung — inklusive aller Tagesgrenzen dazwischen.
        var cursor = date("2026-06-19T00:00:00.000Z")
        let end = date("2026-07-10T00:00:00.000Z")
        while cursor < end {
            let mode = HRUploadModeSchedule.mode(at: cursor, userId: user, now: now, defaults: defaults)
            modesPerDay[calendar.startOfDay(for: cursor), default: []].insert(mode)
            cursor = cursor.addingTimeInterval(3600)
        }

        #expect(modesPerDay.count == 21)
        for (day, modes) in modesPerDay {
            // Genau eine Form pro UTC-Tag: entweder Einzelmessungen ODER
            // Faltungen, nie beides. Das ist die ganze Zusage.
            #expect(modes.count == 1, "UTC-Tag \(day) trägt \(modes.count) Formen: \(modes)")
        }

        /// Und die Segmente liegen, wo sie liegen sollen.
        func mode(_ iso: String) -> HRUploadMode {
            HRUploadModeSchedule.mode(at: date(iso), userId: user, now: now, defaults: defaults)
        }
        #expect(mode("2026-06-20T12:00:00.000Z") == .raw) // vor dem Stichtag
        #expect(mode("2026-06-22T12:00:00.000Z") == .buckets) // ab Stichtag
        #expect(mode("2026-06-25T12:00:00.000Z") == .buckets) // Tipp-Tag unverändert
        #expect(mode("2026-06-26T12:00:00.000Z") == .raw) // Hinweg wirkt
        #expect(mode("2026-06-28T12:00:00.000Z") == .raw) // Tipp-Tag unverändert
        #expect(mode("2026-06-29T12:00:00.000Z") == .buckets) // Rückweg wirkt
        #expect(mode("2026-07-02T12:00:00.000Z") == .buckets) // Tipp-Tag unverändert
        #expect(mode("2026-07-03T12:00:00.000Z") == .raw) // zweiter Hinweg wirkt
    }

    // MARK: - Meinungsänderung vor Mitternacht

    @Test("zweimal tippen vor Mitternacht hebt sich auf — der Tag kommt unverändert an")
    func togglingBackBeforeMidnightCancelsThePendingChange() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        let morning = date("2026-06-25T09:00:00.000Z")
        let evening = date("2026-06-25T21:00:00.000Z")

        HRUploadModeSchedule.setDesiredMode(.raw, userId: user, now: morning, defaults: defaults)
        #expect(HRUploadModeSchedule.pendingChange(userId: user, now: morning, defaults: defaults) != nil)

        // Doch nicht.
        let cancelled = HRUploadModeSchedule.setDesiredMode(
            .buckets, userId: user, now: evening, defaults: defaults
        )
        #expect(cancelled == nil)
        #expect(HRUploadModeSchedule.pendingChange(userId: user, now: evening, defaults: defaults) == nil)
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-26T12:00:00.000Z"), userId: user, now: evening, defaults: defaults
            ) == .buckets
        )
    }

    @Test("mehrfaches Umschalten am selben Tag hinterlässt höchstens eine ausstehende Stufe")
    func repeatedTapsCollapseToOnePendingStep() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        let now = date("2026-06-25T09:00:00.000Z")

        for mode in [HRUploadMode.raw, .buckets, .raw, .buckets, .raw] {
            HRUploadModeSchedule.setDesiredMode(mode, userId: user, now: now, defaults: defaults)
        }
        let changes = HRUploadModeSchedule.changes(userId: user, defaults: defaults)
        #expect(changes.count == 1)
        #expect(changes.first?.mode == .raw)
        #expect(changes.first?.effectiveFrom == date("2026-06-26T00:00:00.000Z"))
    }

    // MARK: - Die Vergangenheit bleibt, wie sie ist

    @Test("eine spätere Umschaltung schreibt abgelaufene Tage nicht um")
    func settledDaysAreNeverRewritten() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: user, now: date("2026-06-25T14:00:00.000Z"), defaults: defaults
        )
        // Die Rohphase 26.06.–28.06. ist gelaufen; jetzt zurück auf Faltungen.
        let back = date("2026-06-28T10:00:00.000Z")
        HRUploadModeSchedule.setDesiredMode(.buckets, userId: user, now: back, defaults: defaults)

        // Ein spät nachgelieferter Wert aus der Rohphase bleibt roh — sonst
        // bekäme ein bereits roh hochgeladener Tag zusätzlich Faltungen.
        let later = date("2026-07-05T10:00:00.000Z")
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-27T03:00:00.000Z"), userId: user, now: later, defaults: defaults
            ) == .raw
        )
        // Und ein nachgelieferter Wert aus der Faltungsphase davor bleibt Faltung.
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-23T03:00:00.000Z"), userId: user, now: later, defaults: defaults
            ) == .buckets
        )
        // Vor dem Stichtag: unverändert roh, wie schon vor dieser Einheit.
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-06-10T03:00:00.000Z"), userId: user, now: later, defaults: defaults
            ) == .raw
        )
    }

    // MARK: - Nebensachen mit Folgen

    @Test("den bereits geltenden Zustand zu wählen plant nichts ein")
    func choosingTheEffectiveModeSchedulesNothing() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        let now = date("2026-06-25T09:00:00.000Z")
        #expect(
            HRUploadModeSchedule.setDesiredMode(.buckets, userId: user, now: now, defaults: defaults) == nil
        )
        #expect(HRUploadModeSchedule.changes(userId: user, defaults: defaults).isEmpty)
    }

    @Test("ausstehende Stufe verschwindet, sobald sie gegriffen hat")
    func pendingClearsOnceEffective() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: user, now: date("2026-06-25T09:00:00.000Z"), defaults: defaults
        )
        let after = date("2026-06-26T00:30:00.000Z")
        #expect(HRUploadModeSchedule.pendingChange(userId: user, now: after, defaults: defaults) == nil)
        #expect(HRUploadModeSchedule.currentMode(userId: user, now: after, defaults: defaults) == .raw)
    }

    @Test("pro Nutzer partitioniert — die Wahl des einen Kontos gilt nicht im anderen")
    func perUserPartitioned() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: "u1", now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        HRBucketCutoverStore.cutover(userId: "u2", now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: "u1", now: date("2026-06-25T09:00:00.000Z"), defaults: defaults
        )
        let now = date("2026-06-27T09:00:00.000Z")
        #expect(HRUploadModeSchedule.currentMode(userId: "u1", now: now, defaults: defaults) == .raw)
        #expect(HRUploadModeSchedule.currentMode(userId: "u2", now: now, defaults: defaults) == .buckets)
    }

    @Test("Abmelden räumt den Plan mit ab — das nächste Konto startet auf der Voreinstellung")
    func clearDropsTheSchedule() {
        let defaults = isolatedDefaults()
        HRBucketCutoverStore.cutover(userId: user, now: date("2026-06-21T14:00:00.000Z"), defaults: defaults)
        HRUploadModeSchedule.setDesiredMode(
            .raw, userId: user, now: date("2026-06-25T09:00:00.000Z"), defaults: defaults
        )
        HRUploadModeSchedule.clear(for: user, defaults: defaults)
        HRBucketCutoverStore.clear(for: user, defaults: defaults)

        #expect(HRUploadModeSchedule.changes(userId: user, defaults: defaults).isEmpty)
        // Frisch scharfgestellt: der laufende Tag bleibt roh, ab morgen Faltungen.
        let now = date("2026-06-30T10:00:00.000Z")
        #expect(HRUploadModeSchedule.currentMode(userId: user, now: now, defaults: defaults) == .raw)
        #expect(
            HRUploadModeSchedule.mode(
                at: date("2026-07-01T00:00:00.000Z"), userId: user, now: now, defaults: defaults
            ) == .buckets
        )
    }
}

// swiftlint:enable force_unwrapping
