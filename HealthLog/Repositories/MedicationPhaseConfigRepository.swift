import Foundation

// MARK: - Phases

/// The four reminder phases of a scheduled dose, named after the dose state
/// they announce (server 1.49.0 web wording), not after the traffic-light
/// colours the wire still carries (`green`, `yellow`, `orange`, `red`).
///
/// - due (`green`): the first reminder, this long before the dose window ends.
/// - stillDue (`yellow`): another reminder, this long before the window ends.
/// - overdue (`orange`): the overdue reminder, this long after the window ended.
/// - missed (`red`): this long after the window the dose counts as missed.
///
/// The server applies them to every scheduled medication (the reminder worker
/// reads them for all), not only to GLP-1 ones.
public enum MedicationReminderPhase: String, CaseIterable, Sendable, Hashable, Identifiable {
    case due
    case stillDue
    case overdue
    case missed

    public var id: String {
        rawValue
    }

    /// The wire prefix: `green` → `greenValue` / `greenMode`.
    var wirePrefix: String {
        switch self {
        case .due: "green"
        case .stillDue: "yellow"
        case .overdue: "orange"
        case .missed: "red"
        }
    }

    /// The phase a `details.issues[].path` such as `"redValue"` is about.
    static func from(issuePath path: String) -> MedicationReminderPhase? {
        let field = path.split(separator: ".").last.map(String.init) ?? path
        return allCases.first { field.hasPrefix($0.wirePrefix) }
    }

    var title: String {
        switch self {
        case .due: String(localized: "med.phases.due", defaultValue: "Due")
        case .stillDue: String(localized: "med.phases.stillDue", defaultValue: "Still due")
        case .overdue: String(localized: "med.phases.overdue", defaultValue: "Overdue")
        case .missed: String(localized: "med.phases.missed", defaultValue: "Missed")
        }
    }

    var hint: String {
        switch self {
        case .due:
            String(
                localized: "med.phases.due.hint",
                defaultValue: "First reminder, this long before the reminder window ends."
            )
        case .stillDue:
            String(
                localized: "med.phases.stillDue.hint",
                defaultValue: "Another reminder, this long before the window ends."
            )
        case .overdue:
            String(
                localized: "med.phases.overdue.hint",
                defaultValue: "A reminder that the dose is overdue, this long after the window ended."
            )
        case .missed:
            String(
                localized: "med.phases.missed.hint",
                defaultValue: "After this long past the window, the dose counts as missed."
            )
        }
    }
}

// MARK: - Wire DTO

/// `GET` / `PUT /api/medications/{id}/phase-config` (server
/// `src/lib/validations/phase-config.ts`): eight flat fields, a whole number
/// from 0 to 1440 and a mode per phase. `MINUTES` is an absolute length,
/// `PERCENT` a share of the dose window.
///
/// The GET answers the stored row (with `id`, `medicationId`, timestamps,
/// all ignored here) or, when none is stored, the server defaults. Decoding is
/// tolerant: a field an older or partial answer lacks reads as its default and
/// an unknown mode as minutes, so the reminder words never fail on a shape.
public struct MedicationPhaseConfig: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Hashable {
        case minutes = "MINUTES"
        case percent = "PERCENT"
    }

    public struct Setting: Sendable, Equatable {
        public var value: Int
        public var mode: Mode

        public init(value: Int, mode: Mode = .minutes) {
            self.value = value
            self.mode = mode
        }

        /// The setting in minutes for a window of `windowMinutes`, rounded
        /// like the server's `Math.round`.
        func minutes(windowMinutes: Int) -> Int {
            switch mode {
            case .minutes: value
            case .percent: Int((Double(value) / 100 * Double(windowMinutes)).rounded())
            }
        }
    }

    public var due: Setting
    public var stillDue: Setting
    public var overdue: Setting
    public var missed: Setting

    /// The schema's bounds for every value (`z.number().int().min(0).max(1440)`).
    public static let valueRange: ClosedRange<Int> = 0 ... 1440

    /// The server's defaults (`DEFAULT_PHASE_CONFIG`): 60 and 30 minutes before
    /// the window ends, overdue right after it, missed 4 hours later.
    public static let defaults = MedicationPhaseConfig(
        due: Setting(value: 60),
        stillDue: Setting(value: 30),
        overdue: Setting(value: 0),
        missed: Setting(value: 240)
    )

    public init(due: Setting, stillDue: Setting, overdue: Setting, missed: Setting) {
        self.due = due
        self.stillDue = stillDue
        self.overdue = overdue
        self.missed = missed
    }

    public subscript(phase: MedicationReminderPhase) -> Setting {
        get {
            switch phase {
            case .due: due
            case .stillDue: stillDue
            case .overdue: overdue
            case .missed: missed
            }
        }
        set {
            switch phase {
            case .due: due = newValue
            case .stillDue: stillDue = newValue
            case .overdue: overdue = newValue
            case .missed: missed = newValue
            }
        }
    }

    /// The phases whose value lies outside ``valueRange``.
    var phasesOutOfRange: [MedicationReminderPhase] {
        MedicationReminderPhase.allCases.filter { !Self.valueRange.contains(self[$0].value) }
    }

    private enum CodingKeys: String, CodingKey {
        case greenValue, greenMode, yellowValue, yellowMode
        case orangeValue, orangeMode, redValue, redMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        func setting(_ value: CodingKeys, _ mode: CodingKeys, _ standard: Setting) -> Setting {
            let number = try? c.decodeIfPresent(Int.self, forKey: value)
            let raw = try? c.decodeIfPresent(String.self, forKey: mode)
            return Setting(
                value: number ?? standard.value,
                mode: raw.flatMap(Mode.init(rawValue:)) ?? standard.mode
            )
        }
        due = setting(.greenValue, .greenMode, fallback.due)
        stillDue = setting(.yellowValue, .yellowMode, fallback.stillDue)
        overdue = setting(.orangeValue, .orangeMode, fallback.overdue)
        missed = setting(.redValue, .redMode, fallback.missed)
    }

    /// Exactly the eight fields the PUT schema names, nothing else.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(due.value, forKey: .greenValue)
        try c.encode(due.mode, forKey: .greenMode)
        try c.encode(stillDue.value, forKey: .yellowValue)
        try c.encode(stillDue.mode, forKey: .yellowMode)
        try c.encode(overdue.value, forKey: .orangeValue)
        try c.encode(overdue.mode, forKey: .orangeMode)
        try c.encode(missed.value, forKey: .redValue)
        try c.encode(missed.mode, forKey: .redMode)
    }
}

// MARK: - 422 bounds

/// A `422` of the phase-config PUT. The server lists every refused field under
/// `details.issues[]` with its `path` (`"redValue"`) and, for a value out of
/// bounds, `minimum` or `maximum` (both optional, server 1.49.0 shared
/// sanitiser). The sheet names the allowed range from them; a bound the issue
/// leaves out is the schema's own (0 or 1440).
public struct MedicationPhaseConfigRefusal: Error, Sendable, Equatable {
    public struct Issue: Sendable, Equatable {
        public let path: String?
        public let minimum: Double?
        public let maximum: Double?

        public init(path: String?, minimum: Double? = nil, maximum: Double? = nil) {
            self.path = path
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    public let issues: [Issue]

    public init(issues: [Issue]) {
        self.issues = issues
    }

    static let routeSuffix = "/phase-config"

    /// The typed refusal for a response of this route, or `nil`. For the
    /// transport's opt-in hook beside ``MeasurementBatchInvalid``.
    static func from(path: String, status: Int, body: Data) -> Self? {
        guard status == 422, path.hasSuffix(routeSuffix) else { return nil }
        return Self(issues: parseIssues(body))
    }

    /// `details.issues[]` of an error envelope; an unreadable body is no issue.
    static func parseIssues(_ body: Data) -> [Issue] {
        guard let decoded = try? JSONDecoder().decode(Body.self, from: body) else { return [] }
        return (decoded.details?.issues ?? []).map {
            Issue(path: $0.path, minimum: $0.minimum, maximum: $0.maximum)
        }
    }

    /// The allowed range for `phase`, from its issue's bounds, else the schema's.
    func allowedRange(for phase: MedicationReminderPhase) -> ClosedRange<Int> {
        let issue = issues.first { $0.path.flatMap(MedicationReminderPhase.from(issuePath:)) == phase }
        return Self.range(minimum: issue?.minimum, maximum: issue?.maximum)
    }

    /// The phases the issues name, in phase order.
    var phases: [MedicationReminderPhase] {
        let named = Set(issues.compactMap { $0.path.flatMap(MedicationReminderPhase.from(issuePath:)) })
        return MedicationReminderPhase.allCases.filter(named.contains)
    }

    /// One line naming the allowed range: per refused phase, or for all values
    /// when no issue names a phase.
    var message: String {
        let named = phases
        guard !named.isEmpty else {
            let range = Self.range(
                minimum: issues.compactMap(\.minimum).max(),
                maximum: issues.compactMap(\.maximum).min()
            )
            return String(
                format: String(localized: "med.phases.error.rangeAll", defaultValue: "Use values from %1$lld to %2$lld."),
                range.lowerBound,
                range.upperBound
            )
        }
        return named.map { phase in
            let range = allowedRange(for: phase)
            return String(
                format: String(localized: "med.phases.error.range", defaultValue: "%1$@: use a value from %2$lld to %3$lld."),
                phase.title,
                range.lowerBound,
                range.upperBound
            )
        }
        .joined(separator: " ")
    }

    private static func range(minimum: Double?, maximum: Double?) -> ClosedRange<Int> {
        let lower = minimum.map { Int($0.rounded(.up)) } ?? MedicationPhaseConfig.valueRange.lowerBound
        let upper = maximum.map { Int($0.rounded(.down)) } ?? MedicationPhaseConfig.valueRange.upperBound
        return lower <= upper ? lower ... upper : MedicationPhaseConfig.valueRange
    }

    private struct Body: Decodable {
        struct Details: Decodable {
            let issues: [WireIssue]?
        }

        struct WireIssue: Decodable {
            let path: String?
            let minimum: Double?
            let maximum: Double?

            private enum CodingKeys: String, CodingKey { case path, minimum, maximum }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let dotted = try? c.decodeIfPresent(String.self, forKey: .path) {
                    path = dotted
                } else if let segments = try? c.decodeIfPresent([String].self, forKey: .path) {
                    path = segments.joined(separator: ".")
                } else {
                    path = nil
                }
                minimum = try? c.decodeIfPresent(Double.self, forKey: .minimum)
                maximum = try? c.decodeIfPresent(Double.self, forKey: .maximum)
            }
        }

        let details: Details?
    }
}

// MARK: - Repository

/// What the phase sheet needs from the server; the repository below in the
/// app, a stub in tests.
public protocol MedicationPhaseConfigProviding: Sendable {
    func phaseConfig(medicationID: String) async throws -> MedicationPhaseConfig
    func savePhaseConfig(_ config: MedicationPhaseConfig, medicationID: String) async throws -> MedicationPhaseConfig
    func resetPhaseConfig(medicationID: String) async throws
}

/// `GET` / `PUT` / `DELETE /api/medications/{id}/phase-config`.
///
/// The write is a settings save the person makes with the sheet open, so it
/// goes out directly under an ``IdempotencyKey`` (a retry of the same tap
/// lands once) and a failure stays on the sheet with the draft intact, rather
/// than being queued: a queued phase change could land after a later one made
/// on the web. The PUT is an upsert, so a repeat is harmless.
public actor MedicationPhaseConfigRepository: MedicationPhaseConfigProviding {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    static func path(_ medicationID: String) -> String {
        "/api/medications/\(medicationID)/phase-config"
    }

    /// The stored phases, or the server defaults when none are stored.
    public func phaseConfig(medicationID: String) async throws -> MedicationPhaseConfig {
        let req: APIRequest<MedicationPhaseConfig> = .get(Self.path(medicationID))
        return try await api.send(req)
    }

    /// Stores all four phases and returns what the server kept. A `422` throws
    /// ``MedicationPhaseConfigRefusal`` with the bounds the server named.
    public func savePhaseConfig(
        _ config: MedicationPhaseConfig,
        medicationID: String
    ) async throws -> MedicationPhaseConfig {
        let req: APIRequest<MedicationPhaseConfig> = try .put(
            Self.path(medicationID),
            body: config,
            idempotencyKey: IdempotencyKey()
        )
        do {
            return try await api.send(req)
        } catch let refusal as MedicationPhaseConfigRefusal {
            throw refusal
        } catch let HLError.server(status, _, _) where status == 422 {
            // The transport hands the body over only where it opts the route
            // in; without it the schema's own bounds are named.
            throw MedicationPhaseConfigRefusal(issues: [])
        }
    }

    /// Drops the stored phases; the server defaults apply again.
    public func resetPhaseConfig(medicationID: String) async throws {
        let req: APIRequest<ResetAnswer> = .delete(Self.path(medicationID), idempotencyKey: IdempotencyKey())
        _ = try await api.send(req)
    }

    /// `{ reset: true }`, read leniently.
    struct ResetAnswer: Decodable, Sendable {
        let reset: Bool?
    }
}
