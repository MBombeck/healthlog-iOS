import Foundation
@testable import HealthLog
import Testing

/// Phase 08 Plan 16 — the DE/EN catalogue coverage for the reminder action and
/// completion-ledger surfaces Plan 08-22 shipped.
///
/// 08-22 deliberately left every new string as a bare localization key ("leave
/// DE/EN values to 08-16") and recorded the consequence honestly: a person
/// opening the reminder detail sheet read `vorsorge.history.title`. No existing
/// gate could see it — `check-strings.sh` looks for catalogue keys with no
/// reference, which is the *other* direction, and it exited 0 at 5,163 keys
/// with zero orphans while all 29 of these were missing. (17-02 removed one of
/// them with the surface that rendered it — see the G1 note below; the census is
/// 28 from 2026-08-23 on.)
///
/// This suite is the direction that was not covered, stated for the exact keys
/// the shipped surfaces name. It asserts three different things, because
/// "the key exists" is the weakest of them:
///
///   1. the **catalogue source** (`Localizable.xcstrings`) carries a non-empty
///      `de` and `en` value for every key;
///   2. the **compiled** `de.lproj` / `en.lproj` tables in the host-app bundle
///      resolve each key to something other than the key itself — which is
///      what the user actually reads, and the only check that would notice a
///      catalogue that failed to compile into the binary;
///   3. the format specifier each call site passes through `String(format:)`
///      is present in **both** locales, so a translation cannot silently drop
///      the number or the date it was written around.
///
/// Two copy constraints from 08-22 are asserted as text rather than left to
/// review, because both are claims about truth and not about tone:
///
///   * `vorsorge.history.empty` must say the ledger **begins with this
///     release**. "No history yet" is a different and false statement for
///     every reminder created before v1.37.20 — the server has no rows to
///     backfill and never will.
///   * `vorsorge.history.unsupported` must say the ledger is not offered **for
///     this reminder**. It is a `404` on a per-reminder capability, not an
///     empty history, and collapsing the two is exactly the confusion
///     `VorsorgeCard.LedgerState` keeps apart in three separate cases.
@Suite("Phase 08 localization keys — DE/EN coverage for the reminder surfaces")
struct Phase8LocalizationKeysTests {
    /// One catalogue key a Phase-8 surface renders, plus the format specifier
    /// its call site passes through `String(format:)`. `nil` means the call
    /// site takes no argument, in which case a stray specifier in either locale
    /// would be rendered literally to the user.
    struct RequiredKey: Sendable {
        let key: String
        let format: String?

        init(_ key: String, format: String? = nil) {
            self.key = key
            self.format = format
        }
    }

    /// The keys `08-22-SUMMARY.md` enumerates, in the order it lists them — 29 at
    /// the time, 28 since 17-02 removed the adherence header (G1).
    /// Every one is a string literal in production source, which is why no
    /// `dynamicKeyPrefixes` baseline entry is required for any of them — a
    /// property `phase8KeysAreNotLaunderedThroughTheBaseline` asserts rather
    /// than assumes.
    static let reminderKeys: [RequiredKey] = [
        // Actions on the detail sheet.
        RequiredKey("vorsorge.action.skip"),
        RequiredKey("vorsorge.action.snooze"),
        RequiredKey("vorsorge.action.snooze.day"),
        RequiredKey("vorsorge.action.snooze.confirm"),
        // Card and sheet state, both read from the server's own row.
        RequiredKey("vorsorge.card.snoozedUntil", format: "%@"),
        RequiredKey("vorsorge.card.snoozed"),
        RequiredKey("vorsorge.card.skipped"),
        RequiredKey("vorsorge.card.skippedCycle"),
        RequiredKey("vorsorge.card.skipCount", format: "%lld"),
        // 17-02 (G1) — `vorsorge.adherence.snoozedCount` stood here for the
        // adherence header's quiet caption. The header was removed on the
        // operator's statement and its seven keys left the catalogue with it, so
        // the required-key row goes too: a RequiredKey for a key nothing renders
        // pins nothing and would have to be satisfied by keeping a dead entry.
        // The tile's own snooze/skip affordances are pinned instead, by
        // `VorsorgeMedicationTileParityTests` and by the 08-22 marker in
        // `VorsorgeReminderHistoryTests`.
        // Ledger chrome.
        RequiredKey("vorsorge.history.title"),
        RequiredKey("vorsorge.history.empty"),
        RequiredKey("vorsorge.history.unsupported"),
        RequiredKey("vorsorge.history.failed"),
        RequiredKey("vorsorge.history.retry"),
        RequiredKey("vorsorge.history.loadMore"),
        // Ledger rows — a total switch over the published enums, plus the two
        // punctuality keys the server derives at write time.
        RequiredKey("vorsorge.history.kind.satisfied"),
        RequiredKey("vorsorge.history.kind.skipped"),
        RequiredKey("vorsorge.history.kind.unknown"),
        RequiredKey("vorsorge.history.onTime"),
        RequiredKey("vorsorge.history.late"),
        RequiredKey("vorsorge.history.source.manual"),
        RequiredKey("vorsorge.history.source.autoMeasurement"),
        RequiredKey("vorsorge.history.source.autoLab"),
        RequiredKey("vorsorge.history.source.telegram"),
        RequiredKey("vorsorge.history.source.vaccination"),
        RequiredKey("vorsorge.history.source.encounter"),
        RequiredKey("vorsorge.history.source.skip"),
        RequiredKey("vorsorge.history.source.unknown")
    ]

    /// Not a Phase-8 key. `scripts/check-missing-strings.sh` — the inverse
    /// check this plan adds — found it on its first run: `LabsChangesCard`
    /// renders `↑ +1.2  ·  clinicalSignals.labs.previous 3.4` because the key
    /// was never added. Pinned here so the fix cannot quietly regress, and
    /// listed separately so the Phase-8 census stays exactly the Phase-8 set.
    static let inheritedKeys: [RequiredKey] = [RequiredKey("clinicalSignals.labs.previous")]

    static var allRequiredKeys: [RequiredKey] {
        reminderKeys + inheritedKeys
    }

    /// The four production files that render them. `VorsorgeAdherenceSummaryCard`
    /// left this list on 2026-08-23 (G1, deleted); `VorsorgeReminderLedgerActions`
    /// took its place, which is where 08-22’s skip/snooze copy now lives.
    static let reminderSurfaces = [
        "HealthLog/Screens/Notifications/MeasurementRemindersScreen.swift",
        "HealthLog/Screens/Notifications/VorsorgeReminderDetailSheet.swift",
        "HealthLog/Screens/Notifications/VorsorgeCardModel.swift",
        "HealthLog/Screens/Notifications/VorsorgeReminderLedgerActions.swift"
    ]

    // MARK: - RED

    @Test("every reminder key carries real, distinct, format-preserving DE and EN copy")
    func reminderCopyIsLocalizedInBothLocales() throws {
        var violations: [String] = []
        let catalog = try Self.catalogEntries()
        let compiled = try [
            "de": Self.lprojBundle(language: "de"),
            "en": Self.lprojBundle(language: "en")
        ]

        for required in Self.allRequiredKeys {
            guard let entry = catalog[required.key] else {
                violations.append("\(required.key): absent from Localizable.xcstrings")
                continue
            }
            var values: [String: String] = [:]
            for language in ["de", "en"] {
                let value = Self.value(in: entry, language: language)
                guard let value, !value.isEmpty else {
                    violations.append("\(required.key): no \(language) value in the catalogue")
                    continue
                }
                values[language] = value

                let resolved = compiled[language]?
                    .localizedString(forKey: required.key, value: "PHASE8_MISSING", table: nil)
                if resolved == "PHASE8_MISSING" {
                    violations.append("\(required.key): the compiled \(language).lproj does not carry it")
                } else if resolved == required.key {
                    violations.append("\(required.key): the compiled \(language).lproj still renders the bare key")
                }

                if let format = required.format {
                    if !value.contains(format) {
                        violations.append("\(required.key): the \(language) value drops the \(format) argument")
                    }
                } else if value.contains("%") {
                    violations.append("\(required.key): the \(language) value carries a stray % specifier")
                }
            }
            if let de = values["de"], let en = values["en"], de == en {
                violations.append("\(required.key): the DE value is identical to the EN source — untranslated")
            }
        }

        violations.append(contentsOf: Self.ledgerAbsenceCopyViolations(catalog))

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: Phase 8 reminder copy is missing or incomplete in the catalogue
            \(violations.joined(separator: "\n"))
            """
        )
    }

    /// The two absent-ledger sentences, asserted for what they claim rather
    /// than for how they read. Both are load-bearing: one denies a history that
    /// never existed, the other denies a capability for one reminder.
    private struct CopyClause: Sendable {
        let key: String
        let language: String
        let phrase: String
        let why: String
    }

    private static let ledgerAbsenceClauses: [CopyClause] = {
        let beginsWithTheRelease =
            "the empty ledger must say it begins with this release, not that there is no history"
        let namesThisReminder =
            "an unsupported ledger must name THIS reminder, not report an empty history"
        return [
            CopyClause(
                key: "vorsorge.history.empty", language: "en",
                phrase: "starts with this app version", why: beginsWithTheRelease
            ),
            CopyClause(
                key: "vorsorge.history.empty", language: "de",
                phrase: "beginnt mit dieser App-Version", why: beginsWithTheRelease
            ),
            CopyClause(
                key: "vorsorge.history.unsupported", language: "en",
                phrase: "this reminder", why: namesThisReminder
            ),
            CopyClause(
                key: "vorsorge.history.unsupported", language: "de",
                phrase: "diese Erinnerung", why: namesThisReminder
            )
        ]
    }()

    private static func ledgerAbsenceCopyViolations(_ catalog: [String: [String: Any]]) -> [String] {
        var violations: [String] = []
        for clause in ledgerAbsenceClauses {
            guard let entry = catalog[clause.key],
                  let value = value(in: entry, language: clause.language) else
            {
                continue // already reported as an absent key or an absent value
            }
            if !value.localizedCaseInsensitiveContains(clause.phrase) {
                violations.append("\(clause.key) [\(clause.language)]: \(clause.why)")
            }
        }
        return violations
    }

    // MARK: - Preservation

    /// Every key this suite requires must still be named by a surface. A key
    /// nobody renders is a catalogue corpse, and this list is exactly the
    /// mechanism that would keep one alive past the screen that used it.
    ///
    /// Source is read comment-stripped: a key mentioned only in a doc comment
    /// does not count, which is the hazard 08-22 caught in one of its own RED
    /// clauses.
    @Test("every required reminder key is still referenced by a reminder surface")
    func requiredKeysAreStillRenderedBySomeSurface() throws {
        let sources = try Self.reminderSurfaces.map { try Self.strippedSource($0) }
        let blob = sources.joined(separator: "\n")
        #expect(blob.count > 10000, "the reminder-surface scan must actually read the four files")

        for required in Self.reminderKeys {
            #expect(
                blob.contains("\"\(required.key)\""),
                "no reminder surface names \(required.key) outside a comment"
            )
        }
    }

    /// 08-22 recorded that no key here needs a `dynamicKeyPrefixes` entry,
    /// because every one is a literal. Asserting it keeps the fix honest: a key
    /// added to the baseline instead of to the catalogue would satisfy
    /// `check-strings.sh` and still render a bare key to the user.
    @Test("no Phase 8 reminder key is laundered through the check-strings baseline")
    func phase8KeysAreNotLaunderedThroughTheBaseline() throws {
        let baseline = try Self.json("scripts/check-strings-baseline.json")
        let prefixes = Array(((baseline["dynamicKeyPrefixes"] as? [String: Any]) ?? [:]).keys)
        let listed = Set(
            ((baseline["serverProvided"] as? [String]) ?? [])
                + ((baseline["testAnchored"] as? [String]) ?? [])
                + ((baseline["knownOrphans"] as? [String]) ?? [])
        )

        for required in Self.allRequiredKeys {
            #expect(
                !listed.contains(required.key),
                "\(required.key) is tolerated by the check-strings baseline instead of being localized"
            )
            for prefix in prefixes {
                #expect(
                    !required.key.hasPrefix(prefix),
                    "\(required.key) is covered by the dynamic prefix `\(prefix)` — it is a literal and needs a real entry"
                )
            }
        }
    }

    /// The Vorsorge copy that already existed does not move. The catalogue
    /// reflow that adds 30 keys is the classic place to lose one.
    @Test("the Vorsorge copy that predates this plan still resolves in both locales")
    func preexistingVorsorgeCopySurvives() throws {
        let frozen = [
            "vorsorge.card.nextDue",
            "vorsorge.card.lastDone",
            "vorsorge.card.markDone",
            "vorsorge.card.measureNow",
            "vorsorge.card.checkIn",
            "vorsorge.card.disabled",
            "vorsorge.card.cadence.custom",
            "clinicalSignals.labs.since"
        ]
        let de = try Self.lprojBundle(language: "de")
        let en = try Self.lprojBundle(language: "en")
        for key in frozen {
            for (language, bundle) in [("de", de), ("en", en)] {
                let resolved = bundle.localizedString(forKey: key, value: "PHASE8_MISSING", table: nil)
                #expect(resolved != "PHASE8_MISSING", "\(key) lost its \(language) entry")
                #expect(resolved != key, "\(key) renders the bare key in \(language)")
            }
        }
    }

    // MARK: - Catalogue and bundle access

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func json(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func catalogEntries() throws -> [String: [String: Any]] {
        let catalog = try json("HealthLog/Resources/Localizable.xcstrings")
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings.count > 5000, "the catalogue read must actually see the app's keys")
        return strings.compactMapValues { $0 as? [String: Any] }
    }

    private static func value(in entry: [String: Any], language: String) -> String? {
        let localizations = entry["localizations"] as? [String: Any]
        let block = localizations?[language] as? [String: Any]
        let unit = block?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    private static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return stripLineComments(from: stripBlockComments(from: text))
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                previous = character
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else
        {
            throw LocalizationTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum LocalizationTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in the host-app bundle — did the catalogue compile?"
            }
        }
    }
}
