import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Contract tests for the `avatarInitials` extension chain.
///
/// v0.11 N4 — the dead `AvatarBadge` view was removed; its composition tests
/// went with it. The initials ladder stays load-bearing (DashboardHeader /
/// EditProfileScreen render it), so we keep locking the deterministic letters
/// the design depends on.
@MainActor
@Suite("avatarInitials contract")
struct AvatarBadgeTests {
    // MARK: - Initials ladder

    @Test(
        "UserProfile.avatarInitials extracts deterministic letters",
        arguments: [
            // v0.6.2.3 bug-fix: hyphenated given names collapse to one
            // initial — `"Anna-Lena Fischer"` reads as one person named
            // "Anna-Lena", so the badge owes the surname's letter next.
            ("Anna-Lena Fischer", nil as String?, "AF"),
            ("Anna Lena Fischer", nil, "AF"),
            ("Anna Lena", nil, "AL"),
            ("anna", nil, "A"),
            ("Anna", nil, "A"),
            ("Anna Lena Fischer Junior", nil, "AJ"),
            ("  Anna  ", nil, "A"),
            ("  Anna-Lena Fischer  ", nil, "AF"),
            ("Übung", nil, "Ü"),
            (nil, "alf", "A"),
            // Underscores no longer split — username `"anna_fischer"` is
            // a single token so the helper returns one initial.
            (nil, "anna_fischer", "A"),
            (nil, nil, "?"),
            ("", "", "?"),
            ("   ", nil, "?"),
            ("é", nil, "É")
        ]
    )
    func initialsExtraction(displayName: String?, username: String?, expected: String) {
        let profile = UserProfile(
            username: username,
            displayName: displayName,
            dateOfBirth: nil,
            gender: nil,
            heightCm: nil,
            locale: nil,
            timezone: nil
        )
        #expect(profile.avatarInitials == expected)
    }

    @Test("User.avatarInitials mirrors UserProfile fallback chain")
    func userAvatarInitialsMirrorsProfile() {
        let user = User(
            id: "u1",
            email: "anna.fischer@example.com",
            username: "anna",
            displayName: "Anna-Lena Fischer",
            createdAt: nil
        )
        #expect(user.avatarInitials == "AF")
    }

    @Test("User.avatarInitials falls through displayName→username")
    func userFallsThroughToUsername() {
        let user = User(
            id: "u1",
            email: nil,
            username: "alf",
            displayName: nil,
            createdAt: nil
        )
        #expect(user.avatarInitials == "A")
    }

    @Test("User.avatarInitials returns '?' when both fields are nil")
    func userReturnsQuestionMarkWhenEmpty() {
        let user = User(id: "u1", email: nil, username: nil, displayName: nil, createdAt: nil)
        #expect(user.avatarInitials == "?")
    }
}
