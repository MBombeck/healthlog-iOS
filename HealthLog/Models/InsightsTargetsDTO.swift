import Foundation

/// Wire-form mirror of `GET /api/insights/targets` (server v1.4.36 W1,
/// route at `src/app/api/insights/targets/route.ts`).
///
/// The endpoint backs the "personal health targets" page — for each
/// MeasurementType the user has a target on, it emits current value +
/// 30-day average + trend + classification band + the 7- and 30-day
/// consistency strip (Berlin-tz daily buckets).
///
/// **Server cache:** 60s TTL keyed by user id, invalidated on any
/// measurement / mood / medication write. iOS-side keeps no second
/// layer — repository hits the route directly and lets the server
/// cache do the heavy lifting.
///
/// **Empty-state semantics:** `range == nil` means the user has no
/// target configured for that type. `current == nil` means no readings
/// in the window. `insufficientData == true` collapses the consistency
/// strip + percentage tile to a placeholder.
public struct InsightsTargetsResponseDTO: Codable, Sendable, Equatable {
    public let targets: [TargetItem]
    public let pageSummary: PageSummary
    public let bpDiastolic: BPDiastolic?
    public let profile: Profile?

    public init(
        targets: [TargetItem],
        pageSummary: PageSummary,
        bpDiastolic: BPDiastolic?,
        profile: Profile?
    ) {
        self.targets = targets
        self.pageSummary = pageSummary
        self.bpDiastolic = bpDiastolic
        self.profile = profile
    }

    /// One target row. The wire field names match the server's
    /// `TargetItem` interface verbatim.
    public struct TargetItem: Codable, Sendable, Equatable, Identifiable {
        public var id: String {
            type
        }

        public let type: String
        public let label: String
        public let current: Double?
        public let average30: Double?
        public let trend: Trend?
        public let unit: String
        public let range: Range?
        public let classification: Classification?
        public let source: String
        public let daysInRange7d: Int
        public let daysLogged7d: Int
        public let daysInRange30d: Int
        public let daysLogged30d: Int
        public let lastMetGoalAt: String?
        public let streakDays: Int
        public let insufficientData: Bool
        public let consistency7d: [ConsistencyBucket?]

        public enum Trend: String, Codable, Sendable, Equatable {
            case up
            case down
            case stable
        }

        public enum ConsistencyBucket: String, Codable, Sendable, Equatable {
            case inBand = "in"
            case nearBand = "near"
            case outBand = "out"
        }

        public struct Range: Codable, Sendable, Equatable {
            public let min: Double
            public let max: Double

            public init(min: Double, max: Double) {
                self.min = min
                self.max = max
            }
        }

        public struct Classification: Codable, Sendable, Equatable {
            public let category: String
            public let color: String

            public init(category: String, color: String) {
                self.category = category
                self.color = color
            }
        }
    }

    public struct PageSummary: Codable, Sendable, Equatable {
        public let targetsMetThisWeek: Int
        public let totalTargets: Int
        public let streakHighlight: StreakHighlight?

        public init(targetsMetThisWeek: Int, totalTargets: Int, streakHighlight: StreakHighlight?) {
            self.targetsMetThisWeek = targetsMetThisWeek
            self.totalTargets = totalTargets
            self.streakHighlight = streakHighlight
        }

        public struct StreakHighlight: Codable, Sendable, Equatable {
            public let metric: String
            public let days: Int

            public init(metric: String, days: Int) {
                self.metric = metric
                self.days = days
            }
        }
    }

    /// BP-specific extra slot — the diastolic counterpart to the
    /// `BLOOD_PRESSURE_SYS` target row. Lives outside the array because
    /// the consistency strip + classification are computed against the
    /// systolic value and the diastolic is rendered alongside the same
    /// tile.
    public struct BPDiastolic: Codable, Sendable, Equatable {
        public let current: Double?
        public let average30: Double?
        public let range: TargetItem.Range?

        public init(current: Double?, average30: Double?, range: TargetItem.Range?) {
            self.current = current
            self.average30 = average30
            self.range = range
        }
    }

    public struct Profile: Codable, Sendable, Equatable {
        public let heightCm: Double?
        public let age: Int?
        public let gender: String?
        public let glucoseUnit: String?

        public init(heightCm: Double?, age: Int?, gender: String?, glucoseUnit: String?) {
            self.heightCm = heightCm
            self.age = age
            self.gender = gender
            self.glucoseUnit = glucoseUnit
        }
    }
}
