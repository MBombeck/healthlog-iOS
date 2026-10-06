// L1 — Personal Records reads English in the English UI.
//
// The screen App Review reaches through "Personal records" was built German
// throughout: the time-range segments ("Allzeit", "Dieses Jahr" …) were German
// words fed to `LocalizedStringKey` with no catalog entry, half the metric names
// were German `String`s, the streak and best-day labels were German, the
// comparison band and every VoiceOver sentence were German, and the number and
// date formatters were pinned to `de_DE`. These tests read the English side of
// each piece, the German side where the de copy must stay as it was, and the
// streak-classifier invariant the localized labels have to keep.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Personal Records English copy (L1)")
    struct PersonalRecordsEnglishCopyTests {
        private static let english = Locale(identifier: "en")
        private static let german = Locale(identifier: "de")

        private static func catalogEntry(_ key: String) throws -> (en: String, de: String) {
            let url = AppGermanCopyGuardTests.repoRoot()
                .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            let entry = try #require(strings[key] as? [String: Any], "\(key) is no catalog key")
            let locs = try #require(entry["localizations"] as? [String: Any])
            func value(_ lang: String) throws -> String {
                let unit = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any]
                return try #require(unit?["value"] as? String, "\(key) has no \(lang) value")
            }
            return try (value("en"), value("de"))
        }

        @Test("time-range segments are catalog keys with English and German copy", arguments: TimeBucket.allCases)
        func bucketLabels(bucket: TimeBucket) throws {
            let entry = try Self.catalogEntry(bucket.label)
            #expect(!AppGermanCopyGuardTests.looksGerman(entry.en), "\(bucket): \(entry.en)")
            #expect(entry.en != entry.de)
        }

        @Test("every metric name reads English under English")
        func metricNamesEnglish() {
            let types = MetricTypeLocalisation.knownTypes
            #expect(types.count >= 30)
            for type in types {
                let label = MetricTypeLocalisation.label(forType: type, locale: Self.english)
                #expect(!AppGermanCopyGuardTests.looksGerman(label), "\(type) → \(label)")
                #expect(!label.contains("."), "\(type) resolved to a raw key: \(label)")
            }
            #expect(MetricTypeLocalisation.label(forType: "HRV", locale: Self.english) == "Heart rate variability")
            #expect(MetricTypeLocalisation.label(forType: "FLIGHTS_CLIMBED", locale: Self.english) == "Flights climbed")
        }

        @Test("the German metric names stay as they were")
        func metricNamesGerman() {
            #expect(MetricTypeLocalisation.label(forType: "HRV", locale: Self.german) == "Herzfrequenzvariabilität")
            #expect(MetricTypeLocalisation.label(forType: "BODY_TEMPERATURE", locale: Self.german) == "Körpertemperatur")
            #expect(MetricTypeLocalisation.label(forType: "AUDIO_EXPOSURE_ENV", locale: Self.german) == "Lärm-Belastung")
            #expect(MetricTypeLocalisation.label(forType: "MOOD", locale: Self.german) == "Stimmung")
        }

        @Test(
            "record, hero, streak and comparison copy has English and German",
            arguments: [
                "records.streak.unit", "records.streak.slot %@ %lld", "records.bestDay.slot",
                "records.delta.vsPrevious %@", "records.a11y.newRecord", "records.a11y.change %@",
                "records.hero.since %@", "records.hero.a11y %@ %@ %@ %@", "records.comparison.a11yHint",
                "records.comparison.a11y %@ %@ %@ %@ %@", "records.comparison.insideBand",
                "records.comparison.belowBetter", "records.comparison.belowWorse",
                "records.comparison.belowCentered", "records.comparison.aboveWorse",
                "records.comparison.aboveBetter", "records.comparison.aboveCentered",
                "benchmark.source.eyebrow"
            ]
        )
        func recordCopy(key: String) throws {
            let entry = try Self.catalogEntry(key)
            #expect(!AppGermanCopyGuardTests.looksGerman(entry.en), "\(key): \(entry.en)")
            #expect(entry.en != entry.de, "\(key) is not translated")
        }

        @Test("a localized streak label still lands in the streak rail, in both languages")
        func streakClassifierInvariant() throws {
            let slot = try Self.catalogEntry("records.streak.slot %@ %lld")
            #expect(slot.en.lowercased().contains("streak"))
            #expect(slot.de.lowercased().contains("serie"))
            // The derivation itself (tests run in German).
            let day = Date(timeIntervalSince1970: 1_780_000_000)
            let calendar = Calendar(identifier: .gregorian)
            let points = (0 ..< 3).map { offset -> SeriesPoint in
                let date = calendar.date(byAdding: .day, value: offset, to: day) ?? day
                return SeriesPoint(id: "p\(offset)", at: date, value: 12000, secondary: nil)
            }
            let records = StreakComputer.derive(
                points: points, kind: .steps, userId: "u1", now: day, calendar: calendar
            )
            let streak = try #require(records.first { $0.id.hasSuffix(".streak") })
            let lowered = (streak.metricSlot ?? "").lowercased()
            #expect(lowered.contains("serie") || lowered.contains("streak"))
            #expect(streak.unit == String(localized: "records.streak.unit"))
        }
    }

#endif
