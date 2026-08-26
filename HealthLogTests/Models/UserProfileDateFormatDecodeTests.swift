import Foundation
@testable import HealthLog
import Testing

/// A360-1 H1 — `UserProfile.dateFormat` decode (server `User.dateFormat`,
/// v1.21.0 / migration 0192). Must decode when present, and tolerate the key
/// being absent (servers pre-v1.21.0) by resolving to `nil` (→ `.auto`).
@Suite("UserProfile dateFormat decode")
struct UserProfileDateFormatDecodeTests {
    private func decode(_ json: String) throws -> UserProfile {
        try JSONDecoder.hlDefault.decode(UserProfile.self, from: Data(json.utf8))
    }

    @Test("Decodes a populated dateFormat enum value")
    func populated() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":"m@example.com","avatarUrl":null,
         "dateOfBirth":null,"gender":null,"heightCm":175,"locale":"de",
         "timezone":"Europe/Berlin","moodReminderEnabled":false,
         "timeFormat":"H24","dateFormat":"DMY"}
        """#
        let profile = try decode(json)
        #expect(profile.dateFormat == "DMY")
        #expect(HLDateFormat(rawValue: profile.dateFormat ?? "") == .dayMonthYear)
    }

    @Test("Tolerates the dateFormat key being absent (pre-v1.21.0 server) → nil")
    func absentKey() throws {
        let json = #"""
        {"username":"anna","displayName":"Anna","email":null,"avatarUrl":null,
         "dateOfBirth":null,"gender":null,"heightCm":null,"locale":null,
         "timezone":"Europe/Berlin"}
        """#
        let profile = try decode(json)
        #expect(profile.dateFormat == nil)
        // Resolves to the safe `.auto` default when nil.
        #expect(HLDateFormat(rawValue: profile.dateFormat ?? "") ?? .auto == .auto)
    }

    @Test("ProfilePatch encodes dateFormat only when set")
    func patchEncodesWhenSet() throws {
        let withValue = ProfilePatch(dateFormat: .some("YMD"))
        let json = try #require(String(data: JSONEncoder().encode(withValue), encoding: .utf8))
        #expect(json.contains("\"dateFormat\":\"YMD\""))

        let omitted = ProfilePatch(displayName: .some("X"))
        let json2 = try #require(String(data: JSONEncoder().encode(omitted), encoding: .utf8))
        #expect(!json2.contains("dateFormat"))
    }
}
