import SwiftUI

// v0.11 N4 — the `AvatarBadge` view + its dead `unreadBadge` affordance were
// removed (the live avatar is `HLProfileAvatar`, which has no unread source).
// The `avatarInitials` fallback chain below stays here because it is still
// used live by `DashboardHeader` / `EditProfileScreen` (and the auth tests).

// MARK: - Initials extraction

public extension UserProfile {
    /// 1-2-letter avatar initials extracted via a deterministic fallback
    /// chain: `displayName` → `username` → "?".
    ///
    /// Hyphens and underscores are treated as part of the same token, so
    /// double-barrelled given names collapse to a single initial — that
    /// matches the way operators read their own name on the badge
    /// (`"Anna-Lena Fischer"` belongs to one human called "Anna-Lena",
    /// not two people called "Anna" and "Lena").
    ///
    /// Examples:
    /// - `"Anna-Lena Fischer"`         → `"AF"`  (hyphen ≠ separator)
    /// - `"Anna Lena Fischer"`         → `"AF"`  (first + last token)
    /// - `"Anna Lena"`                 → `"AL"`  (first + last token)
    /// - `"anna_fischer"`              → `"A"`   (underscore ≠ separator)
    /// - `"anna"`                      → `"A"`
    /// - `"Anna Lena Fischer Junior"`  → `"AJ"`  (first + last token)
    /// - `"Übung"`                      → `"Ü"`   (umlaut preserved)
    /// - `nil` / empty / whitespace     → `"?"`
    ///
    /// **Privacy note:** the result is *non-PII* in the sense that
    /// downstream logging would be uninteresting — we still avoid logging
    /// it because it's a stable user-id surrogate. View-layer only.
    var avatarInitials: String {
        Self.makeInitials(from: displayName, username: username)
    }

    /// Test-friendly pure helper. Public so `User` (and tests) can reuse
    /// the exact same fallback ladder without duplicating logic.
    ///
    /// Split rule: whitespace only (hyphens and underscores stay inside
    /// the token because `"Anna-Lena"` is a single given name, not two
    /// names — splitting on `-` produced `"AL"` for `"Anna-Lena Fischer"`
    /// which contradicted the doc-comment promise of `"AF"`).
    ///
    /// Selection rule: when there are ≥2 whitespace-separated tokens we
    /// take the **first** and the **last** token (given-name + surname),
    /// so middle names don't crowd the surname off the badge. A single
    /// token collapses to its first letter.
    static func makeInitials(from displayName: String?, username: String?) -> String {
        let source = displayName?.trimmedNonEmpty
            ?? username?.trimmedNonEmpty
            ?? ""
        guard !source.isEmpty else { return "?" }
        let parts = source.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return "?" }
        let firstLetter = first.first.map { String($0).uppercased() } ?? ""
        let lastLetter: String = {
            guard parts.count >= 2, let last = parts.last else { return "" }
            return last.first.map { String($0).uppercased() } ?? ""
        }()
        let joined = firstLetter + lastLetter
        return joined.isEmpty ? "?" : joined
    }
}

public extension User {
    /// Convenience that mirrors `UserProfile.avatarInitials` so the
    /// `AuthStore.User` (which is the available identity during cold-launch
    /// before the profile lands) can drive the toolbar badge too.
    var avatarInitials: String {
        UserProfile.makeInitials(from: displayName, username: username)
    }
}

// MARK: - String helper (file-local)

private extension String {
    /// `nil` if the trimmed string is empty, otherwise the trimmed string.
    /// Used so a profile with `displayName = " "` falls through to `username`.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
