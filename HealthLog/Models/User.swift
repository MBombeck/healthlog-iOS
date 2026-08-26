import Foundation

public enum AccountAccessStatus: Sendable, Equatable {
    case absent
    case valid
    case invalid
}

public enum AccountAccessLevel: String, Codable, Sendable, Equatable {
    case read
    case write
    case manage
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum AccountRecordKind: String, Codable, Sendable, Equatable {
    case `self`
    case shared
    case managed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum AccountAccessSection: String, Codable, Sendable, Equatable, Hashable {
    case measurements
    case medications
    case labs
    case profile
    case illness
    case mind
    case cycle
    case documents
}

/// A section grant distinguishes the three server meanings exactly. Missing or
/// malformed data is a fourth, refused state; it is never treated as all.
public enum AccountAccessSections: Sendable, Equatable {
    case all
    case none
    case subset([AccountAccessSection])
    case unavailable

    public func contains(_ section: AccountAccessSection) -> Bool {
        switch self {
        case .all: true
        case .none, .unavailable: false
        case let .subset(sections): sections.contains(section)
        }
    }
}

public struct AccountAccessEntry: Codable, Sendable, Equatable {
    public let accountId: String
    public let username: String
    public let displayName: String?
    public let fullName: String?
    public let level: AccountAccessLevel
    public let recordKind: AccountRecordKind
    public let sections: AccountAccessSections
    /// Effective value, after canonical-level and legacy-consistency checks.
    public let canWrite: Bool

    private enum CodingKeys: String, CodingKey {
        case accountId, username, displayName, fullName, access, level, recordKind, sections, canWrite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(String.self, forKey: .accountId)
        username = try c.decode(String.self, forKey: .username)
        displayName = try? c.decode(String.self, forKey: .displayName)
        fullName = try? c.decode(String.self, forKey: .fullName)

        let legacyAccess = try? c.decode(String.self, forKey: .access)
        let canonical: AccountAccessLevel = if c.contains(.level) {
            (try? c.decode(AccountAccessLevel.self, forKey: .level)) ?? .unknown
        } else {
            switch legacyAccess {
            case "read": .read
            case "write": .write
            default: .unknown
            }
        }
        let decodedKind = (try? c.decode(AccountRecordKind.self, forKey: .recordKind)) ?? .unknown
        let decodedSections = Self.decodeSections(from: c)
        let declaredCanWrite = (try? c.decode(Bool.self, forKey: .canWrite)) ?? false
        let isConsistent = Self.isConsistent(
            level: canonical,
            legacyAccess: legacyAccess,
            sections: decodedSections,
            canWrite: declaredCanWrite
        )

        level = isConsistent ? canonical : .unknown
        recordKind = decodedKind
        sections = isConsistent && decodedKind != .unknown ? decodedSections : .unavailable
        canWrite = isConsistent && declaredCanWrite && canonical != .read && decodedKind != .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(fullName, forKey: .fullName)
        try c.encode(level, forKey: .level)
        try c.encode(recordKind, forKey: .recordKind)
        try c.encode(canWrite, forKey: .canWrite)
        switch sections {
        case .all:
            try c.encodeNil(forKey: .sections)
        case .none:
            try c.encode([AccountAccessSection](), forKey: .sections)
        case let .subset(sections):
            try c.encode(sections, forKey: .sections)
        case .unavailable:
            break
        }
    }

    public func allows(section: AccountAccessSection, write: Bool) -> Bool {
        guard level != .unknown, recordKind != .unknown, sections.contains(section) else { return false }
        return !write || canWrite
    }

    public func allowsWholeRecord(write: Bool) -> Bool {
        guard level != .unknown, recordKind != .unknown, sections == .all else { return false }
        return !write || canWrite
    }

    private static func decodeSections(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> AccountAccessSections {
        guard c.contains(.sections) else { return .unavailable }
        guard (try? c.decodeNil(forKey: .sections)) != true else { return .all }
        guard let raw = try? c.decode([String].self, forKey: .sections) else { return .unavailable }
        guard !raw.isEmpty else { return .none }
        let sections = raw.compactMap(AccountAccessSection.init(rawValue:))
        guard sections.count == raw.count, Set(sections).count == sections.count else { return .unavailable }
        return .subset(sections)
    }

    private static func isConsistent(
        level: AccountAccessLevel,
        legacyAccess: String?,
        sections: AccountAccessSections,
        canWrite: Bool
    ) -> Bool {
        guard level != .unknown, sections != .unavailable else { return false }
        switch level {
        case .read:
            return (legacyAccess == nil || legacyAccess == "read") && !canWrite
        case .write:
            return (legacyAccess == nil || legacyAccess == "write") && canWrite
        case .manage:
            // `manage` describes the account-level role, while `sections`
            // independently scopes the record data exposed to that role.
            // A managed account may therefore legitimately advertise no
            // currently granted health sections without invalidating the role.
            return (legacyAccess == nil || legacyAccess == "write") && canWrite
        case .unknown:
            return false
        }
    }
}

public struct AccountAccess: Codable, Sendable, Equatable {
    public let accounts: [AccountAccessEntry]
    public let active: AccountAccessEntry?
    public let recordKind: AccountRecordKind
    public let canSwitch: Bool

    public static let ownerOnly = AccountAccess(accounts: [], active: nil, recordKind: .self, canSwitch: false)

    public init(
        accounts: [AccountAccessEntry],
        active: AccountAccessEntry?,
        recordKind: AccountRecordKind,
        canSwitch: Bool
    ) {
        self.accounts = accounts
        self.active = active
        self.recordKind = recordKind
        self.canSwitch = canSwitch
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, active, recordKind, canSwitch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let accounts = try c.decode([AccountAccessEntry].self, forKey: .accounts)
        let active = try c.decodeIfPresent(AccountAccessEntry.self, forKey: .active)
        let recordKind = (try? c.decode(AccountRecordKind.self, forKey: .recordKind))
            ?? active?.recordKind
            ?? .self
        let canSwitch = (try? c.decode(Bool.self, forKey: .canSwitch)) ?? !accounts.isEmpty

        guard Set(accounts.map(\.accountId)).count == accounts.count,
              canSwitch == !accounts.isEmpty,
              active == nil ? recordKind == .self : recordKind == active?.recordKind,
              active.map(accounts.contains) ?? true else
        {
            throw DecodingError.dataCorruptedError(
                forKey: .accounts,
                in: c,
                debugDescription: "Account access views disagree"
            )
        }
        self.init(accounts: accounts, active: active, recordKind: recordKind, canSwitch: canSwitch)
    }
}

public struct RecordSession: Codable, Sendable, Equatable {
    public let epoch: Int
    public let scope: String?
}

public struct User: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let email: String?
    public let username: String?
    public let displayName: String?
    /// Optional — the server's native login response (`/api/auth/login` with
    /// `X-Client-Type: native`) returns a minimal `{ id, username }` shape. Full
    /// metadata is filled in via `/api/user/profile` after login.
    public let createdAt: Date?
    public let accountAccess: AccountAccess
    public let accountAccessStatus: AccountAccessStatus
    public let recordSession: RecordSession?

    public init(
        id: String,
        email: String? = nil,
        username: String? = nil,
        displayName: String? = nil,
        createdAt: Date? = nil,
        accountAccess: AccountAccess = .ownerOnly,
        accountAccessStatus: AccountAccessStatus = .absent,
        recordSession: RecordSession? = nil
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.displayName = displayName
        self.createdAt = createdAt
        self.accountAccess = accountAccess
        self.accountAccessStatus = accountAccessStatus
        self.recordSession = recordSession
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, username, displayName, createdAt, accountAccess, recordSession
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try? c.decode(String.self, forKey: .email)
        username = try? c.decode(String.self, forKey: .username)
        displayName = try? c.decode(String.self, forKey: .displayName)
        createdAt = try? c.decode(Date.self, forKey: .createdAt)
        recordSession = try? c.decode(RecordSession.self, forKey: .recordSession)
        if !c.contains(.accountAccess) {
            accountAccess = .ownerOnly
            accountAccessStatus = .absent
        } else if let decoded = try? c.decode(AccountAccess.self, forKey: .accountAccess) {
            accountAccess = decoded
            accountAccessStatus = .valid
        } else {
            accountAccess = .ownerOnly
            accountAccessStatus = .invalid
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        if accountAccessStatus != .absent {
            try c.encode(accountAccess, forKey: .accountAccess)
        }
        try c.encodeIfPresent(recordSession, forKey: .recordSession)
    }
}

public struct UserProfile: Codable, Sendable, Equatable {
    public let username: String?
    public let displayName: String?
    /// Server-side email (Prisma `User.email`). Surfaced by `GET /api/user/profile`
    /// — added v0.4.1 / M2-A6 so the Personal-Settings sheet hero can show the
    /// email under the display name without a second `AuthStore.user` round-trip.
    /// PATCH does not accept this field (email-change is a separate flow).
    public let email: String?
    /// v0.8.0 W11 — self-hosted avatar URL (server v1.5.5). Relative path of
    /// the shape `/api/user/avatar/{userId}?v=<updatedAtMs>` when the user has
    /// uploaded a photo, `nil` otherwise. The `?v=` suffix is a cache-buster:
    /// a re-upload flips the timestamp so the client invalidates its cached
    /// bytes. The path is owner-scoped + authenticated — the image must be
    /// fetched through the app's pinned `APIClient` session (the bytes are
    /// PHI-adjacent), never a bare `URL` in `AsyncImage`. Optional on the wire
    /// because older servers (pre-v1.5.5) omit the key entirely; clients then
    /// fall back to the initials monogram.
    public let avatarUrl: String?
    public let dateOfBirth: Date?
    public let gender: String?
    public let heightCm: Int?
    public let locale: String?
    public let timezone: String?
    /// v0.5.4.3 HP5 / server PR #190 — opt-in flag for the daily
    /// `MOOD_REMINDER` cron tick at 22:00 local time. Surfaced as a
    /// toggle in `SettingsNotificationsScreen` and gates the server-
    /// side `runMoodReminderTick` per-user scan. Optional on the wire
    /// because older servers (pre-PR-190) omit the key — we default
    /// to `false` client-side so the toggle reads "off" until the
    /// server confirms it's actually opted in.
    public let moodReminderEnabled: Bool?
    /// v0.10.0 — extended patient-identity fields surfaced by both
    /// `GET /api/user/profile` and `GET /api/auth/me` (server v1.7.0). The
    /// full legal name + insurer feed the Doctor-Report cover + the FHIR
    /// Patient resource; all three are optional on the wire (older servers
    /// omit the keys entirely) so the decode stays tolerant.
    public let fullName: String?
    /// v0.10.0 — health insurer (Krankenkasse). Plaintext, optional.
    public let insurerName: String?
    /// v0.10.0 — German insurance number (KVNR). Returned in plaintext
    /// (server decrypts on read, fail-soft to `nil` on a key-rotation gap).
    /// Sensitive PII — must **never** be logged. Lives in-memory only,
    /// alongside the rest of the in-memory profile; never persisted to
    /// UserDefaults or any local cache beyond the existing SWR profile path.
    public let insuranceNumber: String?
    /// v0.11.0 — German Institutionskennzeichen (IKNR) of the health
    /// insurer: the 9-digit machine-resolvable insurer id. Optional,
    /// nullable (empty→nil). Echoed on `GET /api/user/profile` and accepted
    /// on PATCH (server v1.8.6, field `insurerIkNumber`). Feeds the FHIR
    /// `Coverage` payor → contained `Organization.identifier`
    /// (`http://fhir.de/sid/arge-ik/iknr`). Identifying PII — must **never**
    /// be logged. In-memory only, same lifetime as the rest of the profile.
    public let insurerIkNumber: String?
    /// M3 (AUDIT-PARITY-v11612) — time-format preference (`AUTO | H12 | H24`),
    /// surfaced by `GET /api/user/profile` (server `User.timeFormat`, default
    /// `AUTO`). Optional / nil against servers that omit the key — the client
    /// then keeps the device-locale (`AUTO`) hour cycle. Drives every rendered
    /// clock through ``HLTimeFormat``.
    public let timeFormat: String?
    /// A360-1 H1 — date-format preference (`AUTO | DMY | MDY | YMD`), surfaced
    /// by `GET /api/user/profile` (server `User.dateFormat`, default `AUTO`,
    /// migration 0192 / server v1.21.0). Optional / nil against servers that
    /// omit the key — the client then keeps the device-locale (`AUTO`) field
    /// order. Drives every rendered date through ``HLDateFormat``.
    public let dateFormat: String?

    public init(
        username: String?,
        displayName: String?,
        email: String? = nil,
        avatarUrl: String? = nil,
        dateOfBirth: Date?,
        gender: String?,
        heightCm: Int?,
        locale: String?,
        timezone: String?,
        moodReminderEnabled: Bool? = nil,
        fullName: String? = nil,
        insurerName: String? = nil,
        insuranceNumber: String? = nil,
        insurerIkNumber: String? = nil,
        timeFormat: String? = nil,
        dateFormat: String? = nil
    ) {
        self.username = username
        self.displayName = displayName
        self.email = email
        self.avatarUrl = avatarUrl
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.heightCm = heightCm
        self.locale = locale
        self.timezone = timezone
        self.moodReminderEnabled = moodReminderEnabled
        self.fullName = fullName
        self.insurerName = insurerName
        self.insuranceNumber = insuranceNumber
        self.insurerIkNumber = insurerIkNumber
        self.timeFormat = timeFormat
        self.dateFormat = dateFormat
    }
}

public extension UserProfile {
    /// Returns a copy with only `timeFormat` replaced — keeps the optimistic
    /// `SettingsStore.setTimeFormat(_:)` setter terse (the struct is otherwise
    /// immutable). A360-1 H1 / M3.
    func replacingTimeFormat(_ value: String) -> UserProfile {
        UserProfile(
            username: username, displayName: displayName, email: email,
            avatarUrl: avatarUrl, dateOfBirth: dateOfBirth, gender: gender,
            heightCm: heightCm, locale: locale, timezone: timezone,
            moodReminderEnabled: moodReminderEnabled, fullName: fullName,
            insurerName: insurerName, insuranceNumber: insuranceNumber,
            insurerIkNumber: insurerIkNumber, timeFormat: value, dateFormat: dateFormat
        )
    }

    /// Returns a copy with only `dateFormat` replaced. A360-1 H1.
    func replacingDateFormat(_ value: String) -> UserProfile {
        UserProfile(
            username: username, displayName: displayName, email: email,
            avatarUrl: avatarUrl, dateOfBirth: dateOfBirth, gender: gender,
            heightCm: heightCm, locale: locale, timezone: timezone,
            moodReminderEnabled: moodReminderEnabled, fullName: fullName,
            insurerName: insurerName, insuranceNumber: insuranceNumber,
            insurerIkNumber: insurerIkNumber, timeFormat: timeFormat, dateFormat: value
        )
    }
}

public struct AuthSession: Codable, Sendable, Equatable {
    public let token: String
    public let refreshToken: String?
    /// 60-day rotating refresh window per `05-auth-flows.md §2.1`. Nil for
    /// the cookie-only web path; non-nil whenever the native login bundle
    /// was issued.
    public let refreshTokenExpiresAt: Date?
    public let user: User
    public let expiresAt: Date?

    public init(
        token: String,
        refreshToken: String? = nil,
        refreshTokenExpiresAt: Date? = nil,
        user: User,
        expiresAt: Date? = nil
    ) {
        self.token = token
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.user = user
        self.expiresAt = expiresAt
    }
}
