import Foundation
@testable import HealthLog
import Testing

/// **08-18 — the accepted v1.37.20 measurement-reminder contract, frozen before adoption.**
///
/// Pinned to the immutable tag `v1.37.20` (commit
/// `3a2c0e757e5f0a4ea8bf6be899b3a04547ddd423`), whose `docs/api/openapi.yaml`
/// hashes to `839b960a45ba9b91ec70b04eed49ae26ce868ea3e8aec83300da4db9ff1d985e`.
/// `origin/main` was already three patch releases ahead at acceptance and its
/// extracted reminder fragment was byte-identical, so later branch movement is
/// audit context and never an invalidation input.
///
/// **Nothing in this suite comes from the announcement in iOS issue #92.** The
/// fixtures under `HealthLogTests/Fixtures/Server/v1.37.20/` are an extract of
/// the tagged bytes — every non-comment line of the YAML is byte-identical to a
/// line of the accepted source — and the issue was read only afterwards, to
/// enumerate what it had left unspecified. It left rather a lot: both response
/// envelopes, the pagination envelope and its bounds, the status sets, whether
/// skip declares an absent body or `{}`, whether the additive fields are
/// optional, and every value of the `source` enum.
///
/// The suite has one failing clause and three passing ones, on purpose.
///
/// - ``acceptedContractHasNoIOSConsumer()`` is the behavioural RED that Plan
///   08-19 closes. It is behavioural rather than a build failure because it
///   probes the decoded row through `Mirror` and reads the repository as text;
///   a clause written as `row.skipCount` could not compile today, and
///   `assert-behavioral-red.sh` rightly refuses a compile error as proof of
///   nothing.
/// - The other three pin what the contract *says* and must pass now and after
///   adoption. If freezing the contract were itself broken, they would say so
///   instead of hiding inside the RED.
@Suite("Measurement reminder v1.37.20")
struct MeasurementReminderV13720ContractTests {
    // MARK: - Reflective probe

    /// What a named property on a decoded value actually is. "The property does
    /// not exist", "it exists and is nil" and "it exists and carries a value"
    /// are three different answers, and a contract with required-but-nullable
    /// fields needs all three to be distinguishable.
    enum Probe: Equatable {
        case absent
        case null
        case present(String)

        var label: String {
            switch self {
            case .absent: "absent"
            case .null: "null"
            case let .present(value): value
            }
        }
    }

    static func probe(_ subject: Any, _ property: String) -> Probe {
        for child in Mirror(reflecting: subject).children where child.label == property {
            let mirror = Mirror(reflecting: child.value)
            guard mirror.displayStyle == .optional else { return .present(String(describing: child.value)) }
            guard let unwrapped = mirror.children.first?.value else { return .null }
            return .present(String(describing: unwrapped))
        }
        return .absent
    }

    /// What a clause demands of a probed property. Dates are asserted as
    /// "carries a value" rather than by their rendered text: the contract being
    /// pinned is that the instant survives at all, and pinning
    /// `String(describing:)` of a `Date` would make this suite fail on a
    /// formatting change that means nothing.
    enum Demand {
        case null
        case anyValue
        case exactly(String)

        func matches(_ probe: Probe) -> Bool {
            switch (self, probe) {
            case (.null, .null): true
            case (.anyValue, .present): true
            case let (.exactly(expected), .present(actual)): expected == actual
            default: false
            }
        }

        var label: String {
            switch self {
            case .null: "null"
            case .anyValue: "a value"
            case let .exactly(value): value
            }
        }
    }

    // MARK: - The RED — Plan 08-19's consumer does not exist yet

    /// Every clause below is a thing the accepted contract publishes and the iOS
    /// side does not yet consume. None of them asserts a *value* the server
    /// might change; they assert that a field or route the tag publishes has
    /// somewhere to land.
    @Test("The accepted skip, snooze and ledger contract reaches an iOS consumer")
    func acceptedContractHasNoIOSConsumer() throws {
        var violations: [String] = []

        // 1. The three additive DTO fields. All three are in the published
        //    `required` list, so every reminder the server sends carries them —
        //    a client that drops them is discarding truth on every list load.
        let skipped = try Self.reminder("reminderSkipped")
        Self.record(skipped, "snoozedUntil", .null, "reminderSkipped", into: &violations)
        Self.record(skipped, "lastSkippedAt", .anyValue, "reminderSkipped", into: &violations)
        Self.record(skipped, "skipCount", .exactly("3"), "reminderSkipped", into: &violations)

        let snoozed = try Self.reminder("reminderSnoozed")
        Self.record(snoozed, "snoozedUntil", .anyValue, "reminderSnoozed", into: &violations)
        Self.record(snoozed, "lastSkippedAt", .null, "reminderSnoozed", into: &violations)
        Self.record(snoozed, "skipCount", .exactly("0"), "reminderSnoozed", into: &violations)

        // A never-skipped reminder must read 0 skips and two nulls. `skipCount`
        // 0 and `lastSkippedAt` null agree here, but they are different fields
        // with different jobs, and a `snoozedUntil` of null must never be
        // confused with a snooze that has already elapsed.
        let pristine = try Self.reminder("reminderPristine")
        Self.record(pristine, "snoozedUntil", .null, "reminderPristine", into: &violations)
        Self.record(pristine, "lastSkippedAt", .null, "reminderPristine", into: &violations)
        Self.record(pristine, "skipCount", .exactly("0"), "reminderPristine", into: &violations)

        // 2. The three routes. Read from the repository's own source text with
        //    comments stripped, so the doc block that lists today's five routes
        //    cannot be mistaken for an implementation of tomorrow's three.
        let repository = try Self.strippedSource("HealthLog/Repositories/MeasurementReminderRepository.swift")
        for route in ["/skip", "/snooze", "/history"] where !repository.contains(route) {
            violations.append("MeasurementReminderRepository calls no \(route) route")
        }

        // 3. The ledger row model. The server publishes `MeasurementReminderEvent`
        //    with six required fields; iOS has no type to decode it into, which
        //    is why `GET /history` has no caller.
        let models = try Self.strippedSource("HealthLog/Models/MeasurementReminderRow.swift")
        if !models.contains("MeasurementReminderEvent") {
            violations.append("no MeasurementReminderEvent model exists to decode a ledger row")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: accepted skip/snooze/history contract has no iOS consumer")
    }

    // MARK: - What the frozen contract says (passes now and after adoption)

    /// The YAML fixture is an extract, and this clause is what makes that
    /// claim checkable rather than decorative. It reads the fragment's own
    /// recorded provenance and then the shapes the routes actually declare.
    @Test("The frozen fragment carries the accepted v1.37.20 reminder surface")
    func frozenFragmentCarriesTheAcceptedSurface() throws {
        let yaml = try Self.text("measurement-reminder-openapi-consumed.yaml")

        // Identity of the accepted input, recorded in the fragment itself.
        #expect(yaml.contains("# tag        : v1.37.20"))
        #expect(yaml.contains("3a2c0e757e5f0a4ea8bf6be899b3a04547ddd423"))
        #expect(yaml.contains("839b960a45ba9b91ec70b04eed49ae26ce868ea3e8aec83300da4db9ff1d985e"))
        #expect(yaml.contains("16abea94dac4046602a26f68095e58d5966482e3f47aa956932d7c5112ba2b06"))

        // Exactly the seven reminder paths, and nothing else: a path key is a
        // line at exactly two spaces of indentation. Comment lines are dropped
        // first so the header's prose cannot be counted as contract.
        let body = Self.withoutComments(yaml)
        let paths = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                guard line.hasPrefix("  /"), line.hasSuffix(":") else { return nil }
                let key = line.dropFirst(2).dropLast()
                return key.contains(" ") ? nil : String(key)
            }
        #expect(Set(paths) == [
            "/api/measurement-reminders",
            "/api/measurement-reminders/{id}",
            "/api/measurement-reminders/{id}/satisfy",
            "/api/measurement-reminders/{id}/complete",
            "/api/measurement-reminders/{id}/skip",
            "/api/measurement-reminders/{id}/snooze",
            "/api/measurement-reminders/{id}/history"
        ])

        // Skip declares NO request body; snooze declares a required one. The
        // announcement never settled "absent versus {}", and the two routes
        // answer it differently, so the distinction is pinned rather than
        // assumed.
        let skip = try #require(Self.pathBlock(body, "/api/measurement-reminders/{id}/skip"))
        #expect(!skip.contains("requestBody"))
        #expect(skip.contains("$ref: \"#/components/schemas/MeasurementReminderSkipEnvelope\""))

        let snooze = try #require(Self.pathBlock(body, "/api/measurement-reminders/{id}/snooze"))
        #expect(snooze.contains("requestBody"))
        #expect(snooze.contains("$ref: \"#/components/schemas/MeasurementReminderSnooze\""))
        #expect(snooze.contains("$ref: \"#/components/schemas/MeasurementReminderSnoozeEnvelope\""))

        // Pagination is a real envelope with real bounds, and `limit`/`offset`
        // are the query names — none of which the announcement specified.
        let history = try #require(Self.pathBlock(body, "/api/measurement-reminders/{id}/history"))
        #expect(history.contains("name: limit"))
        #expect(history.contains("default: 50"))
        #expect(history.contains("maximum: 100"))
        #expect(history.contains("name: offset"))
        #expect(history.contains("$ref: \"#/components/schemas/MeasurementReminderHistoryEnvelope\""))

        // The same status set on all three new routes.
        for block in [skip, snooze, history] {
            for status in ["\"200\"", "\"401\"", "\"403\"", "\"404\"", "\"422\"", "\"429\""] {
                #expect(block.contains(status), "a v1.37.20 route lost status \(status)")
            }
        }

        // The additive fields are REQUIRED, not optional — every reminder
        // carries them, so a tolerant "maybe absent" model would be modelling a
        // server that does not exist.
        let dto = try #require(Self.schemaBlock(body, "MeasurementReminderDTO"))
        for field in ["snoozedUntil", "lastSkippedAt", "skipCount"] {
            #expect(dto.contains("        \(field):"), "DTO lost property \(field)")
            #expect(dto.contains("        - \(field)"), "DTO no longer requires \(field)")
        }
        #expect(dto.contains("additionalProperties: false"))

        // The ledger row, its two enums and its six required fields.
        let event = try #require(Self.schemaBlock(body, "MeasurementReminderEvent"))
        for field in ["id", "kind", "occurredAt", "onTime", "source", "createdAt"] {
            #expect(event.contains("        - \(field)"), "event no longer requires \(field)")
        }
        for kind in ["SATISFIED", "SKIPPED"] {
            #expect(event.contains("            - \(kind)"), "event lost kind \(kind)")
        }
        for source in ["manual", "auto_measurement", "auto_lab", "telegram", "vaccination", "encounter", "skip"] {
            #expect(event.contains("            - \(source)"), "event lost source \(source)")
        }

        // Skip and snooze do NOT share a response shape: skip carries a
        // `skipped` flag beside the reminder, snooze carries the reminder alone.
        let skipPayload = try #require(Self.schemaBlock(body, "MeasurementReminderSkip"))
        #expect(skipPayload.contains("        skipped:"))
        #expect(skipPayload.contains("        - skipped"))
        #expect(skipPayload.contains("        - reminder"))
        let snoozeBody = try #require(Self.schemaBlock(body, "MeasurementReminderSnooze"))
        #expect(snoozeBody.contains("        - until"))
        #expect(snoozeBody.contains("format: date"))
    }

    /// The payload fixture is representative, not captured, and every key it
    /// uses is a key the frozen schemas publish. This clause reads the payloads
    /// as the wire truth Plan 08-19 will decode.
    @Test("The representative payloads carry only published keys and server-derived truth")
    func representativePayloadsMatchTheFrozenSchemas() throws {
        let fixture = try Self.fixture()

        let provenance = try #require(fixture["_provenance"] as? [String: Any])
        #expect(provenance["tag"] as? String == "v1.37.20")
        #expect(provenance["tagCommit"] as? String == "3a2c0e757e5f0a4ea8bf6be899b3a04547ddd423")
        #expect(
            provenance["relevantFragmentSha256"] as? String
                == "16abea94dac4046602a26f68095e58d5966482e3f47aa956932d7c5112ba2b06"
        )

        // Skip is idempotent: `skipped: false` is a real forward-only outcome,
        // not an error, and the reminder still comes back canonical.
        let applied = try #require(fixture["skipAppliedEnvelope"] as? [String: Any])
        let appliedData = try #require(applied["data"] as? [String: Any])
        #expect(appliedData["skipped"] as? Bool == true)
        #expect(appliedData["reminder"] is [String: Any])
        let noOp = try #require(fixture["skipNoOpEnvelope"] as? [String: Any])
        let noOpData = try #require(noOp["data"] as? [String: Any])
        #expect(noOpData["skipped"] as? Bool == false)
        #expect(noOpData["reminder"] is [String: Any])

        // Snooze's envelope has no flag — the asymmetry is the contract.
        let snooze = try #require(fixture["snoozeAppliedEnvelope"] as? [String: Any])
        let snoozeData = try #require(snooze["data"] as? [String: Any])
        #expect(Set(snoozeData.keys) == ["reminder"])
        let snoozeRequest = try #require(fixture["snoozeRequestBody"] as? [String: Any])
        #expect(Set(snoozeRequest.keys) == ["until"])
        #expect(snoozeRequest["until"] as? String == "2026-08-24")

        // The ledger page: newest first, with its own `meta` distinct from the
        // transport's `meta.requestId`.
        let history = try #require(fixture["historyFirstPage"] as? [String: Any])
        let page = try #require(history["data"] as? [String: Any])
        let events = try #require(page["events"] as? [[String: Any]])
        #expect(events.count == 3)
        let occurred = events.compactMap { $0["occurredAt"] as? String }
        #expect(occurred == occurred.sorted(by: >), "the ledger page must be newest first")
        let meta = try #require(page["meta"] as? [String: Any])
        #expect(meta["total"] as? Int == 3)
        #expect(meta["limit"] as? Int == 50)
        #expect(meta["offset"] as? Int == 0)
        // `error` is an explicit JSON null in the published envelope, not an
        // absent key — `NSNull` rather than nothing.
        #expect(history["error"] is NSNull)

        // An empty ledger is honest, not a failure: history begins at the
        // release that introduced it and nothing can be backfilled, so "no rows"
        // is the correct answer for every reminder that predates it.
        let empty = try #require(fixture["historyEmptyLedger"] as? [String: Any])
        let emptyPage = try #require(empty["data"] as? [String: Any])
        #expect((emptyPage["events"] as? [[String: Any]])?.isEmpty == true)
        #expect((emptyPage["meta"] as? [String: Any])?["total"] as? Int == 0)
    }

    /// Freezing a contract must not disturb the surface already shipping. Every
    /// reminder payload here — including the three that carry fields the model
    /// has never seen — still decodes into today's `MeasurementReminderRow`, so
    /// the RED above is about an absent consumer and not about a broken one.
    @Test("Today's reminder decode tolerates the additive v1.37.20 fields")
    func todaysDecodeToleratesTheAdditiveFields() throws {
        for scenario in ["reminderPristine", "reminderSnoozed", "reminderSkipped", "legacyReminderWithoutLedgerFields"] {
            let row = try Self.reminder(scenario)
            #expect(!row.id.isEmpty, "\(scenario) lost its id")
            #expect(!row.label.isEmpty, "\(scenario) lost its label")
            #expect(row.enabled, "\(scenario) lost its enabled flag")
        }

        // The pre-v1.37.20 payload omits exactly the three additive keys and is
        // the shape every stale SWR cache blob still has, so it must survive.
        let legacy = try Self.reminder("legacyReminderWithoutLedgerFields")
        #expect(legacy.origin == .coach)
        #expect(legacy.lastSatisfiedAt != nil)

        // The existing render-only fields still arrive unharmed.
        let snoozed = try Self.reminder("reminderSnoozed")
        #expect(snoozed.measurementType == "BLOOD_PRESSURE_SYS")
        #expect(snoozed.intervalDays == 30)
        #expect(snoozed.nextDueAt != nil)
        #expect(snoozed.origin == .vorsorge)

        let skipped = try Self.reminder("reminderSkipped")
        #expect(skipped.location == "Hautarztpraxis Mitte")
        #expect(skipped.measurementType == nil, "a free-text screening reminder has no auto-resolve target")
    }

    // MARK: - Helpers

    private static func record(
        _ subject: Any,
        _ property: String,
        _ demand: Demand,
        _ context: String,
        into violations: inout [String]
    ) {
        let actual = probe(subject, property)
        guard !demand.matches(actual) else { return }
        violations.append("\(context).\(property) is \(actual.label), expected \(demand.label)")
    }

    /// Drops `#` comment lines. The YAML fixture's prose header names the very
    /// fields and routes the assertions look for, so scanning it unstripped
    /// would let a comment satisfy a contract clause.
    static func withoutComments(_ yaml: String) -> String {
        yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// One `paths` entry, bounded to its own block: from its two-space key line
    /// to the next one. Bounding matters — an unbounded `contains` would let the
    /// snooze route's `requestBody` satisfy a clause about the skip route.
    static func pathBlock(_ yaml: String, _ path: String) -> String? {
        block(yaml, opening: "  \(path):", indent: 2)
    }

    /// One `components.schemas` entry, bounded the same way at four spaces.
    static func schemaBlock(_ yaml: String, _ name: String) -> String? {
        block(yaml, opening: "    \(name):", indent: 4)
    }

    private static func block(_ yaml: String, opening: String, indent: Int) -> String? {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { String($0) == opening }) else { return nil }
        var collected: [Substring] = [lines[start]]
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                collected.append(line)
                continue
            }
            let lead = line.prefix { $0 == " " }.count
            if lead <= indent { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    /// Swift source with `//` comments removed. The repository's doc block lists
    /// today's routes in prose, so a clause asking "is there a /skip call" would
    /// otherwise be answered by a sentence. Block comments are not stripped and
    /// do not need to be: the assertion below proves the file has none, which
    /// also keeps this helper clear of the ordering defect that truncates a file
    /// when a `/*` sits inside a `//` comment.
    static func strippedSource(_ relativePath: String) throws -> String {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!source.contains("/*"), "\(relativePath) gained a block comment; the line-only stripper is no longer sound")
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex ..< marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func reminder(_ scenario: String) throws -> MeasurementReminderRow {
        let root = try fixture()
        let object = try #require(root[scenario] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.hlDefault.decode(MeasurementReminderRow.self, from: data)
    }

    static func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("measurement-reminder-server-truth.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    private static func fixtureURL(_ name: String) -> URL {
        repositoryRoot().appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.20/\(name)")
    }

    private static func repositoryRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Models
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
    }
}
