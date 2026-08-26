import Foundation
@testable import HealthLog
import Testing

/// **08-17 — the published v1.37.19 medication truth at the model boundary.**
///
/// Pinned to the immutable tag `v1.37.19` (commit
/// `d8cbe2596fb9612cfda82b047611178884351c7b`) whose `docs/api/openapi.yaml`
/// hashes to `75c7279f251936411c434fae77cd72b4f31c9ef2da467727c885956a50bf9994`.
/// Later movement of `origin/main` is audit context, never an invalidation
/// input — the fixtures in `HealthLogTests/Fixtures/ServerContracts/v1.37.19/`
/// carry that tag's bytes and this suite reads only them.
///
/// Three separations are load-bearing and each has its own clause:
///
/// 1. **raw vs resolved.** `MedicationSchedule.unitsPerDose` is the user's
///    per-slot EDIT INTENT and is nullable — `null` means "inherit the
///    medication-level value". `resolvedUnitsPerDose` is the server's
///    EFFECTIVE read value and is `required` in the published schema. Losing
///    the first makes an edit sheet fabricate an override the user never set;
///    losing the second makes the client re-derive an inheritance rule the
///    server already owns.
/// 2. **null vs zero.** `stockDosesRemaining` / `runwayDays` are
///    `integer | null`. `null` = inventory tracking is off (or no consuming
///    cadence is derivable); `0` = tracking is on and the supply ran out.
///    Collapsing them turns "we don't know" into a confident "empty".
/// 3. **read vs write.** `resolvedUnitsPerDose` is server-computed. It may
///    ride a decode, and it may sit in the on-device cache, but it must never
///    leave the device in a create or update body.
///
/// The field reads go through `Mirror` on purpose. That keeps the suite
/// compile-clean against the model as it stands *before* the fields exist, so
/// the RED is behavioural (the value is not propagated) rather than a build
/// failure — and it keeps meaning the same thing afterwards, because it asks
/// the decoded value, not the source text.
@Suite("Medication server truth v1.37.19")
struct MedicationServerTruthDecodeTests {
    // MARK: - Reflective field probe

    /// What a named field on a decoded value actually is. The three states the
    /// contract cares about are distinct: the property does not exist at all,
    /// it exists and is `nil`, or it exists and carries a number.
    enum FieldProbe: Equatable {
        case absent
        case null
        case number(Double)
        case other(String)

        var label: String {
            switch self {
            case .absent: "absent"
            case .null: "null"
            case let .number(value): "\(value)"
            case let .other(text): "other(\(text))"
            }
        }
    }

    static func probe(_ subject: Any, _ field: String) -> FieldProbe {
        for child in Mirror(reflecting: subject).children where child.label == field {
            let mirror = Mirror(reflecting: child.value)
            guard mirror.displayStyle == .optional else { return numeric(child.value) }
            guard let unwrapped = mirror.children.first?.value else { return .null }
            return numeric(unwrapped)
        }
        return .absent
    }

    private static func numeric(_ value: Any) -> FieldProbe {
        if let double = value as? Double { return .number(double) }
        if let int = value as? Int { return .number(Double(int)) }
        return .other(String(describing: value))
    }

    private static func check(
        _ subject: Any,
        _ field: String,
        _ expected: FieldProbe,
        _ context: String,
        into violations: inout [String]
    ) {
        let actual = probe(subject, field)
        guard actual != expected else { return }
        violations.append("\(context).\(field) is \(actual.label), expected \(expected.label)")
    }

    // MARK: - Clause 1 + 2 — the propagation contract

    @Test("Raw and resolved slot doses plus nullable stock and runway reach the model")
    func serverTruthFieldsPropagateIntoTheModel() throws {
        var violations: [String] = []

        // Per-slot doses: one slot inherits (raw null), one overrides (raw ½).
        let slotAware = try Self.wire("slotAwareTruth")
        let slots = try #require(slotAware.schedules)
        try #require(slots.count == 2)
        Self.check(slots[0], "unitsPerDose", .null, "wire.schedules[0]", into: &violations)
        Self.check(slots[0], "resolvedUnitsPerDose", .number(1), "wire.schedules[0]", into: &violations)
        Self.check(slots[1], "unitsPerDose", .number(0.5), "wire.schedules[1]", into: &violations)
        Self.check(slots[1], "resolvedUnitsPerDose", .number(0.5), "wire.schedules[1]", into: &violations)

        // Slot-aware medication stock, on the wire shape.
        Self.check(slotAware, "stockDosesRemaining", .number(45), "wire", into: &violations)
        Self.check(slotAware, "runwayDays", .number(30), "wire", into: &violations)

        // …and all four again after `toDomain()`, which is what the UI reads.
        let domain = slotAware.toDomain()
        Self.check(domain, "stockDosesRemaining", .number(45), "domain", into: &violations)
        Self.check(domain, "runwayDays", .number(30), "domain", into: &violations)
        let entries = domain.schedule.entries
        try #require(entries.count == 2)
        Self.check(entries[0], "unitsPerDose", .null, "domain.entries[0]", into: &violations)
        Self.check(entries[0], "resolvedUnitsPerDose", .number(1), "domain.entries[0]", into: &violations)
        Self.check(entries[1], "unitsPerDose", .number(0.5), "domain.entries[1]", into: &violations)
        Self.check(entries[1], "resolvedUnitsPerDose", .number(0.5), "domain.entries[1]", into: &violations)

        // Tracking off: an explicit server `null` stays nil and never becomes 0.
        let off = try Self.wire("trackingOff")
        Self.check(off, "stockDosesRemaining", .null, "trackingOff.wire", into: &violations)
        Self.check(off, "runwayDays", .null, "trackingOff.wire", into: &violations)
        let offDomain = off.toDomain()
        Self.check(offDomain, "stockDosesRemaining", .null, "trackingOff.domain", into: &violations)
        Self.check(offDomain, "runwayDays", .null, "trackingOff.domain", into: &violations)

        // Exhausted: a real 0 stays 0 and never becomes nil.
        let exhausted = try Self.wire("exhausted")
        Self.check(exhausted, "stockDosesRemaining", .number(0), "exhausted.wire", into: &violations)
        Self.check(exhausted, "runwayDays", .number(0), "exhausted.wire", into: &violations)
        let exhaustedDomain = exhausted.toDomain()
        Self.check(exhaustedDomain, "stockDosesRemaining", .number(0), "exhausted.domain", into: &violations)
        Self.check(exhaustedDomain, "runwayDays", .number(0), "exhausted.domain", into: &violations)

        // The raw per-slot intent is the half that MAY travel. Slot 1 carries an
        // explicit ½, and a write body rebuilt from the decoded rows has to say
        // so — otherwise a schedule edit silently drops the user's override.
        let rebuilt = try #require(String(data: JSONEncoder().encode(slots), encoding: .utf8))
        if !rebuilt.contains("\"unitsPerDose\":0.5") {
            violations.append("a write body rebuilt from the decoded slots drops the raw 0.5 override")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: v1.37.19 fields are not propagated")
    }

    // MARK: - Clause 3 — compatibility and the write boundary

    @Test("Absent server truth still decodes and resolvedUnitsPerDose never enters a write body")
    func legacyPayloadsDecodeAndWritesStayRawOnly() throws {
        // A pre-v1.37.19 payload (and every stale local cache blob shaped like
        // one) omits all four fields. It must still decode, and the absence
        // must not be read as an exhausted supply.
        let legacy = try Self.wire("legacyWithoutServerTruth")
        let legacyDomain = legacy.toDomain()
        #expect(legacyDomain.schedule.entries.count == 1)
        #expect(legacyDomain.effectiveUnitsPerDose == 1.0)
        #expect(Self.probe(legacy, "stockDosesRemaining") != .number(0))
        #expect(Self.probe(legacy, "runwayDays") != .number(0))
        #expect(Self.probe(legacyDomain, "stockDosesRemaining") != .number(0))
        #expect(Self.probe(legacyDomain, "runwayDays") != .number(0))

        // The write bodies carry the DECODED server rows — that is exactly the
        // read-modify-write path a schedule edit takes. If the resolved figure
        // were writable, this is where it would leak, so the DTOs under test
        // are built by decoding the fixture rather than by hand.
        let slotAware = try Self.wire("slotAwareTruth")
        let schedules = try #require(slotAware.schedules)
        let encoder = JSONEncoder()
        let bodies: [(String, Data)] = try [
            ("schedules", encoder.encode(schedules)),
            ("create", encoder.encode(MedicationsRepository.MedicationCreate(
                name: "Metformin", dose: "1000 mg", unitsPerDose: 1, schedules: schedules
            ))),
            ("patch", encoder.encode(MedicationsRepository.MedicationPatch(schedules: schedules)))
        ]
        for (name, data) in bodies {
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("resolvedUnitsPerDose"), "\(name) body leaks the server-resolved dose")
            #expect(!text.contains("stockDosesRemaining"), "\(name) body leaks aggregated stock")
            #expect(!text.contains("runwayDays"), "\(name) body leaks the computed runway")
        }
    }

    // MARK: - The typed surface, and where the resolved figure may live

    /// The clauses above read through `Mirror` so they could fail behaviourally
    /// before the properties existed. This one reads them as what they now are —
    /// typed `Double?` / `Int?` — and pins the one asymmetry that the write
    /// guard could otherwise be mistaken for: `resolvedUnitsPerDose` is barred
    /// from the wire, **not** from the device. It has to survive the SWR cache,
    /// or a cold launch would show a supply figure the server never sent.
    @Test("Typed fields carry the truth and the on-device cache keeps the resolved dose")
    func typedFieldsSurviveTheCacheButNotTheWire() throws {
        let slotAware = try Self.wire("slotAwareTruth")
        let slots = try #require(slotAware.schedules)
        #expect(slots[0].unitsPerDose == nil)
        #expect(slots[0].resolvedUnitsPerDose == 1)
        #expect(slots[1].unitsPerDose == 0.5)
        #expect(slots[1].resolvedUnitsPerDose == 0.5)
        #expect(slotAware.stockDosesRemaining == 45)
        #expect(slotAware.runwayDays == 30)

        // Cache round-trip: encode the DOMAIN value the store holds and read it
        // back, exactly as a cold launch does.
        let domain = slotAware.toDomain()
        let cached = try JSONDecoder.hlDefault.decode(
            Medication.self, from: JSONEncoder.hlDefault.encode(domain)
        )
        #expect(cached.stockDosesRemaining == 45)
        #expect(cached.runwayDays == 30)
        #expect(cached.schedule.entries.first?.resolvedUnitsPerDose == 1)
        #expect(cached.schedule.entries.first?.unitsPerDose == nil)
        #expect(cached.schedule.entries.last?.unitsPerDose == 0.5)

        // Tracking off: nil is not zero, at every hop.
        let off = try Self.wire("trackingOff").toDomain()
        #expect(off.stockDosesRemaining == nil)
        #expect(off.runwayDays == nil)
        // Exhausted: zero is not nil.
        let exhausted = try Self.wire("exhausted").toDomain()
        #expect(exhausted.stockDosesRemaining == 0)
        #expect(exhausted.runwayDays == 0)

        // A pre-v1.37.19 row leaves the resolved figure genuinely unknown rather
        // than re-deriving the inheritance rule on the client.
        let legacySlots = try #require(Self.wire("legacyWithoutServerTruth").schedules)
        #expect(legacySlots[0].resolvedUnitsPerDose == nil)
        #expect(legacySlots[0].unitsPerDose == nil)
    }

    // MARK: - Provenance — the fixtures are an extract, not a re-specification

    @Test("The checked-in fragments carry only accepted v1.37.19 shapes")
    func fixturesAreAnExtractOfTheAcceptedContract() throws {
        let yaml = try Self.text("openapi-medication-cadence.yaml")

        // Identity of the accepted input, recorded in the fragment itself.
        #expect(yaml.contains("tag        : v1.37.19"))
        #expect(yaml.contains("d8cbe2596fb9612cfda82b047611178884351c7b"))
        #expect(yaml.contains("75c7279f251936411c434fae77cd72b4f31c9ef2da467727c885956a50bf9994"))

        // Only the four pinned properties were extracted. Comment lines carry
        // prose (and name the fields), so the census reads declaration lines
        // only — a `key:` at exactly eight spaces of indentation.
        let declarations = yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .compactMap { line -> String? in
                guard line.hasPrefix("        ") else { return nil }
                let body = line.dropFirst(8)
                guard !body.hasPrefix(" "), !body.hasPrefix("-"), body.hasSuffix(":") else { return nil }
                return String(body.dropLast())
            }
        #expect(Set(declarations) == ["unitsPerDose", "resolvedUnitsPerDose", "stockDosesRemaining", "runwayDays"])

        // Requiredness and nullability, as published.
        #expect(yaml.contains("        resolvedUnitsPerDose:\n          type: number\n"))
        #expect(yaml.contains("- resolvedUnitsPerDose"))
        #expect(yaml.contains("- stockDosesRemaining"))
        #expect(yaml.contains("- runwayDays"))
        // `unitsPerDose`, `stockDosesRemaining` and `runwayDays` are each a
        // nullable union — six blocks across the four schemas;
        // `resolvedUnitsPerDose` alone is a bare, non-nullable `type: number`.
        #expect(yaml.components(separatedBy: "- type: \"null\"").count - 1 == 6)
        #expect(declarations.count == 8)

        // The payload fixture names the same immutable inputs and covers the
        // three states the decode clause distinguishes.
        let payload = try Self.fixture()
        let provenance = try #require(payload["_provenance"] as? [String: Any])
        #expect(provenance["tag"] as? String == "v1.37.19")
        #expect(provenance["tagCommit"] as? String == "d8cbe2596fb9612cfda82b047611178884351c7b")
        #expect(
            provenance["openapiSha256"] as? String
                == "75c7279f251936411c434fae77cd72b4f31c9ef2da467727c885956a50bf9994"
        )
        for scenario in ["slotAwareTruth", "trackingOff", "exhausted", "legacyWithoutServerTruth"] {
            #expect(payload[scenario] is [String: Any], "missing fixture scenario \(scenario)")
        }
    }

    // MARK: - Fixture loading

    static func wire(_ scenario: String) throws -> MedicationWireDTO {
        let root = try fixture()
        let object = try #require(root[scenario] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: data)
    }

    static func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("medication-dose-fields.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    private static func fixtureURL(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Models
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("HealthLogTests/Fixtures/ServerContracts/v1.37.19/\(name)")
    }
}
