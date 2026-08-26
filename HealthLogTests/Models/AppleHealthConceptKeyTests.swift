import Foundation
@testable import HealthLog
import Testing

/// **CU-10 / GH #47** — the stable-identity seam of the Apple Health medication
/// mirror.
///
/// `HKHealthConceptIdentifier` cannot be constructed in a unit test, so the
/// reader's HealthKit half (archiving) is not what these pin. They pin the half
/// that carries the guarantee: the same archived bytes always hash to the same
/// key, the key has a shape the server's stability guard accepts, and the guard's
/// own rule table is reproduced faithfully enough to refuse a pointer-shaped id
/// before it reaches the wire.
@Suite("AppleHealthConceptKey — stable mirror identity")
struct AppleHealthConceptKeyTests {
    // MARK: - Determinism

    @Test("The same archived identifier yields the same key on every derivation")
    func derivationIsDeterministic() {
        let bytes = Data("HKHealthConceptIdentifier:rxnorm:29046".utf8)
        let first = AppleHealthConceptKey.derive(fromArchivedIdentifier: bytes)
        let second = AppleHealthConceptKey.derive(fromArchivedIdentifier: bytes)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    /// The reader's real pipeline is `NSKeyedArchiver(requiringSecureCoding:) →
    /// derive`. Two independent archiving passes over the same value stand in for
    /// two process runs over the same concept: the whole pipeline — not just the
    /// hash — has to land on one key. This is the property whose absence minted
    /// 23 phantom medication rows.
    @Test("Two independent archive→derive passes over the same value agree")
    func archiveThenDeriveIsStableAcrossPasses() throws {
        let concept = NSUUID(uuidString: "8AD2A9CB-3F0C-4E4D-9C1E-4B7E2A1D6F30")
        let identifier = try #require(concept)

        func key() throws -> String {
            let archived = try NSKeyedArchiver.archivedData(
                withRootObject: identifier,
                requiringSecureCoding: true
            )
            return AppleHealthConceptKey.derive(fromArchivedIdentifier: archived)
        }

        #expect(try key() == key())
    }

    @Test("Different concepts get different keys")
    func distinctConceptsGetDistinctKeys() {
        let a = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("concept-A".utf8))
        let b = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("concept-B".utf8))
        #expect(a != b)
    }

    // MARK: - Shape

    @Test("The derived key is 64 lowercase hex chars — inside the server's 128-char externalId cap")
    func derivedKeyShape() {
        let key = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("x".utf8))
        #expect(key.count == 64)
        #expect(key.count <= 128)
        #expect(AppleHealthConceptKey.isDerivedKey(key))
        #expect(key == key.lowercased())
    }

    @Test("A derived key passes the server's stability guard")
    func derivedKeyIsStableByTheServerRule() {
        let key = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("x".utf8))
        #expect(AppleHealthConceptKey.classify(key) == nil)
    }

    @Test(
        "isDerivedKey rejects every non-scheme shape",
        arguments: [
            "<HKHealthConceptIdentifier: 0x12568db80>",
            "0x12568db80",
            "",
            "concept-A",
            "8AD2A9CB-3F0C-4E4D-9C1E-4B7E2A1D6F30",
            // 63 chars — one short.
            String(repeating: "a", count: 63),
            // 64 chars but not hex.
            String(repeating: "z", count: 64),
            // 64 hex chars, uppercase — not the shape we mint.
            String(repeating: "A", count: 64),
        ]
    )
    func isDerivedKeyRejectsForeignShapes(_ value: String) {
        #expect(!AppleHealthConceptKey.isDerivedKey(value))
    }

    // MARK: - The server's unstable-identifier rule (v1.32.37)

    @Test(
        "Pointer-shaped identifiers are classified, mirroring src/lib/validations/external-id.ts",
        arguments: [
            ("", UnstableExternalIDShape.blank),
            ("   ", .blank),
            ("\n\t", .blank),
            ("0x12568db80", .pointerAddress),
            ("0X12568DB80", .pointerAddress),
            ("<HKHealthConceptIdentifier: 0x12568db80>", .objectDescription),
            ("<NSObject: 0x600000c1a2b0>", .objectDescription),
            ("<Foo: 0x1; bar=2>", .objectDescription),
            ("apple:<Foo: 0x1234>", .objectDescription),
        ]
    )
    func classifiesUnstableShapes(_ value: String, _ expected: UnstableExternalIDShape) {
        #expect(AppleHealthConceptKey.classify(value) == expected)
    }

    /// The false-positive cost is a client that can no longer sync at all, so the
    /// rule stays narrow: every identifier shape this system actually receives
    /// has to survive it.
    @Test(
        "Real identifier shapes are never refused",
        arguments: [
            "8AD2A9CB-3F0C-4E4D-9C1E-4B7E2A1D6F30",
            "3f0c4e4d-9c1e-4b7e-2a1d-6f30ad2a9cb1",
            "stats:HKQuantityTypeIdentifierStepCount:2026-07-25",
            "HKQuantityTypeIdentifierStepCount",
            "whoop:123456",
            "0xdeadbeefZZ",
            "a0x1b",
            "<not a pointer>",
            "value<a>b0x1",
            String(repeating: "a1", count: 32),
        ]
    )
    func acceptsRealIdentifierShapes(_ value: String) {
        #expect(AppleHealthConceptKey.classify(value) == nil)
    }

    @Test("The batch skip reason matches the server's wire constant")
    func skipReasonConstant() {
        #expect(AppleHealthConceptKey.unstableExternalIDReason == "unstable_external_id")
    }
}
