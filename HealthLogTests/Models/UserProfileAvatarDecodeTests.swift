import Foundation
@testable import HealthLog
import Testing

/// **v0.8.0 W11 — UserProfile.avatarUrl decode.**
///
/// The self-hosted avatar URL rides on the profile payload. It must decode
/// when present, surface `nil` on an explicit JSON null, and tolerate the key
/// being absent entirely (older servers pre-v1.5.5) without throwing.
@Suite("UserProfile avatarUrl decode")
struct UserProfileAvatarDecodeTests {
    private func decode(_ json: String) throws -> UserProfile {
        try JSONDecoder.hlDefault.decode(UserProfile.self, from: Data(json.utf8))
    }

    @Test("Decodes a populated avatarUrl with the ?v= cache-buster intact")
    func populated() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":"m@example.com",
         "avatarUrl":"/api/user/avatar/u1?v=1716800000000",
         "dateOfBirth":null,"gender":null,"heightCm":175,
         "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false}
        """#
        let profile = try decode(json)
        #expect(profile.avatarUrl == "/api/user/avatar/u1?v=1716800000000")
        #expect(profile.displayName == "Anna")
    }

    @Test("Decodes an explicit null avatarUrl as nil")
    func explicitNull() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":null,"avatarUrl":null,
         "dateOfBirth":null,"gender":null,"heightCm":null,
         "locale":null,"timezone":"Europe/Berlin"}
        """#
        let profile = try decode(json)
        #expect(profile.avatarUrl == nil)
    }

    @Test("Tolerates the avatarUrl key being absent (pre-v1.5.5 server)")
    func absent() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":null,
         "dateOfBirth":null,"gender":null,"heightCm":null,
         "locale":null,"timezone":"Europe/Berlin"}
        """#
        let profile = try decode(json)
        #expect(profile.avatarUrl == nil)
        #expect(profile.username == "anna")
    }

    // MARK: - v0.10.0 patient-identity fields

    @Test("Decodes fullName / insurerName / insuranceNumber / insurerIkNumber from a GET payload")
    func patientIdentityPopulated() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":"m@example.com",
         "avatarUrl":null,"dateOfBirth":null,"gender":null,"heightCm":175,
         "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false,
         "fullName":"Anna-Lena Fischer","insurerName":"Beispielkasse",
         "insuranceNumber":"A123456789","insurerIkNumber":"123456789"}
        """#
        let profile = try decode(json)
        #expect(profile.fullName == "Anna-Lena Fischer")
        #expect(profile.insurerName == "Beispielkasse")
        #expect(profile.insuranceNumber == "A123456789")
        #expect(profile.insurerIkNumber == "123456789")
    }

    @Test("insurerIkNumber round-trips through encode + decode")
    func insurerIkNumberRoundTrips() throws {
        let original = UserProfile(
            username: "anna", displayName: "Anna", dateOfBirth: nil, gender: nil,
            heightCm: nil, locale: nil, timezone: nil, insurerIkNumber: "123456789"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(UserProfile.self, from: data)
        #expect(decoded.insurerIkNumber == "123456789")
    }

    @Test("Decodes explicit null patient-identity fields as nil")
    func patientIdentityExplicitNull() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":null,"avatarUrl":null,
         "dateOfBirth":null,"gender":null,"heightCm":null,
         "locale":null,"timezone":"Europe/Berlin",
         "fullName":null,"insurerName":null,"insuranceNumber":null,"insurerIkNumber":null}
        """#
        let profile = try decode(json)
        #expect(profile.fullName == nil)
        #expect(profile.insurerName == nil)
        #expect(profile.insuranceNumber == nil)
        #expect(profile.insurerIkNumber == nil)
    }

    @Test("Tolerates the patient-identity keys being absent (pre-v1.7.0 server)")
    func patientIdentityAbsent() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":null,"avatarUrl":null,
         "dateOfBirth":null,"gender":null,"heightCm":null,
         "locale":null,"timezone":"Europe/Berlin"}
        """#
        let profile = try decode(json)
        #expect(profile.fullName == nil)
        #expect(profile.insurerName == nil)
        #expect(profile.insuranceNumber == nil)
        #expect(profile.insurerIkNumber == nil)
        #expect(profile.username == "anna")
    }
}
