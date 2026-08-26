import Foundation
@testable import HealthLog
import Testing

/// Locks the on-wire shape of `ProfilePatch`. The server's
/// `applyProfileUpdate` distinguishes between "key absent → leave value"
/// and "key present, null → clear value". Swift's standard `Codable`
/// synthesis can't express that distinction; our hand-rolled
/// `encode(to:)` must.
///
/// These tests guard the contract: each `String??` field must omit its
/// JSON key when `.none`, emit `null` for `.some(nil)`, and emit the
/// value verbatim for `.some(.some(...))`. Added v0.4.1 / M2-A6.
@Suite("ProfilePatch on-wire encoding")
struct ProfilePatchEncodingTests {
    private func encode(_ patch: ProfilePatch) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(patch)
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [String: Any] ?? [:]
    }

    @Test("Empty patch encodes to an empty JSON object")
    func emptyPatchEmitsEmptyObject() throws {
        let json = try encode(ProfilePatch())
        #expect(json.isEmpty)
    }

    @Test("isEmpty agrees with omitting every field")
    func isEmptyMatchesNoFields() {
        #expect(ProfilePatch().isEmpty == true)
        #expect(ProfilePatch(displayName: .some("Anna")).isEmpty == false)
        #expect(ProfilePatch(displayName: .some(nil)).isEmpty == false)
    }

    @Test("displayName .some(value) emits key with the value")
    func displayNamePresent() throws {
        let json = try encode(ProfilePatch(displayName: .some("Anna-Lena")))
        #expect(json["displayName"] as? String == "Anna-Lena")
        #expect(json.count == 1)
    }

    @Test("displayName .some(nil) emits explicit null")
    func displayNameClear() throws {
        let json = try encode(ProfilePatch(displayName: .some(nil)))
        #expect(json.keys.contains("displayName"))
        #expect(json["displayName"] is NSNull)
    }

    @Test("displayName .none omits the key entirely")
    func displayNameAbsent() throws {
        // CU-17 / #71 — canonical server spelling is uppercase; the encoder is
        // a verbatim pass-through, so the fixture uses the real literal.
        let json = try encode(ProfilePatch(gender: .some("MALE")))
        #expect(!json.keys.contains("displayName"))
        #expect(json["gender"] as? String == "MALE")
    }

    @Test("heightCm round-trips as Int")
    func heightCmRoundTrips() throws {
        let json = try encode(ProfilePatch(heightCm: .some(178)))
        #expect(json["heightCm"] as? Int == 178)
    }

    @Test("heightCm .some(nil) emits null")
    func heightCmClear() throws {
        let json = try encode(ProfilePatch(heightCm: .some(nil)))
        #expect(json["heightCm"] is NSNull)
    }

    @Test("dateOfBirth round-trips as ISO-8601 string")
    func dobRoundTrips() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "1990-05-15T00:00:00Z"))
        let json = try encode(ProfilePatch(dateOfBirth: .some(date)))
        let value = json["dateOfBirth"] as? String
        #expect(value?.hasPrefix("1990-05-15") == true)
    }

    @Test("Multi-field patch encodes all dirty keys, omits clean keys")
    func multiFieldPatch() throws {
        let json = try encode(
            ProfilePatch(
                displayName: .some("Anna"),
                gender: .some(nil),
                heightCm: .some(178)
            )
        )
        #expect(json["displayName"] as? String == "Anna")
        #expect(json["gender"] is NSNull)
        #expect(json["heightCm"] as? Int == 178)
        #expect(!json.keys.contains("dateOfBirth"))
        #expect(!json.keys.contains("locale"))
        #expect(json.count == 3)
    }

    @Test("locale .some(\"en\") encodes the literal locale tag")
    func localeRoundTrips() throws {
        let json = try encode(ProfilePatch(locale: .some("en")))
        #expect(json["locale"] as? String == "en")
    }

    // MARK: - v0.10.0 patient-identity fields

    @Test("Patient-identity .some(value) fields emit their keys with values")
    func patientIdentityPresent() throws {
        let json = try encode(
            ProfilePatch(
                fullName: .some("Anna-Lena Fischer"),
                insurerName: .some("Beispielkasse"),
                insuranceNumber: .some("A123456789"),
                insurerIkNumber: .some("123456789")
            )
        )
        #expect(json["fullName"] as? String == "Anna-Lena Fischer")
        #expect(json["insurerName"] as? String == "Beispielkasse")
        #expect(json["insuranceNumber"] as? String == "A123456789")
        #expect(json["insurerIkNumber"] as? String == "123456789")
        #expect(json.count == 4)
    }

    @Test("Patient-identity .some(nil) emits explicit null to clear")
    func patientIdentityClear() throws {
        let json = try encode(
            ProfilePatch(
                fullName: .some(nil),
                insurerName: .some(nil),
                insuranceNumber: .some(nil),
                insurerIkNumber: .some(nil)
            )
        )
        #expect(json["fullName"] is NSNull)
        #expect(json["insurerName"] is NSNull)
        #expect(json["insuranceNumber"] is NSNull)
        #expect(json["insurerIkNumber"] is NSNull)
    }

    @Test("Patient-identity .none omits the keys entirely")
    func patientIdentityAbsent() throws {
        let json = try encode(ProfilePatch(displayName: .some("Anna")))
        #expect(!json.keys.contains("fullName"))
        #expect(!json.keys.contains("insurerName"))
        #expect(!json.keys.contains("insuranceNumber"))
        #expect(!json.keys.contains("insurerIkNumber"))
    }

    @Test("isEmpty reflects patient-identity fields")
    func isEmptyReflectsIdentity() {
        #expect(ProfilePatch(fullName: .some("X")).isEmpty == false)
        #expect(ProfilePatch(insurerName: .some(nil)).isEmpty == false)
        #expect(ProfilePatch(insuranceNumber: .some("A123456789")).isEmpty == false)
        #expect(ProfilePatch(insurerIkNumber: .some("123456789")).isEmpty == false)
    }

    @Test("insurerIkNumber round-trips as a string; .none omits the key")
    func insurerIkNumberWire() throws {
        let present = try encode(ProfilePatch(insurerIkNumber: .some("123456789")))
        #expect(present["insurerIkNumber"] as? String == "123456789")
        #expect(present.count == 1)

        let absent = try encode(ProfilePatch(displayName: .some("Anna")))
        #expect(!absent.keys.contains("insurerIkNumber"))
    }
}
