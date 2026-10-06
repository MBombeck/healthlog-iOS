import Foundation

// #97 / #115 · 0.4 — the partial-save half of the profile write answer.

/// One field the server skipped on a partial profile save — an element of
/// `rejectedFields` in the `PATCH /api/user/profile` / `PUT /api/auth/profile`
/// 200 answer (server `SanitisedZodIssue`, `src/lib/api-response.ts`):
/// `{ path, code, message }`, `path` being the Zod path joined with `.`.
///
/// `code` is the validator code (`too_big`, `too_small`, `invalid_type`, …) or
/// `rate_limited` for an email change past the hourly budget. `message` is the
/// server's machine prose — kept for logs, never shown verbatim; the app
/// localizes from `path` + `code`.
public struct ProfileRejectedField: Decodable, Sendable, Equatable, Hashable {
    public let path: String
    public let code: String
    public let message: String?

    public init(path: String, code: String, message: String? = nil) {
        self.path = path
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case path, code, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        // Tolerant beyond the published contract: a missing code still names
        // the field — the person learns WHICH value did not land.
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

/// The `PATCH /api/user/profile` 200 answer: the profile after the patch plus
/// the fields that were NOT written. `rejectedFields` is absent on a clean
/// save, so ``isPartial`` is the one question a caller asks.
public struct ProfilePatchResult: Decodable, Sendable, Equatable {
    public let profile: UserProfile
    public let rejectedFields: [ProfileRejectedField]

    public var isPartial: Bool {
        !rejectedFields.isEmpty
    }

    public init(profile: UserProfile, rejectedFields: [ProfileRejectedField] = []) {
        self.profile = profile
        self.rejectedFields = rejectedFields
    }

    private enum CodingKeys: String, CodingKey {
        case rejectedFields
    }

    public init(from decoder: Decoder) throws {
        // The profile fields and `rejectedFields` share one object.
        profile = try UserProfile(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rejectedFields = try c.decodeLossyArray(ProfileRejectedField.self, forKey: .rejectedFields)
    }
}
