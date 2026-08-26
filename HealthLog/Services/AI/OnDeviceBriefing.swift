import Foundation

/// MDR-safe-by-design briefing shape consumed by `DailyBriefingHero` and
/// other on-device renderers. The fields are deliberately **observational**
/// — diagnostic / predictive / prescriptive output is filtered out by
/// `MDRSafetyFilter` before this struct is ever surfaced.
///
/// The struct is isomorphic to the server's `DailyBriefing` (R4 §2.6) so
/// renderers can switch sources without view-layer churn.
///
/// **Why not `@Generable` here?** Apple's `@Generable` macro requires
/// `FoundationModels`, which is iOS 26+. To keep `OnDeviceBriefing`
/// callable from iOS-18 code paths (fallback wiring), this struct is the
/// plain transport type; the `@Generable` mirror used at the model call
/// site lives in `OnDeviceBriefingService` under a `#if canImport`
/// + `@available(iOS 26.0, *)` gate.
public struct OnDeviceBriefing: Sendable, Equatable {
    public var summary: String
    public var keyFindings: [String]
    public var actionableNudges: [String]
    public var confidence: Float
    public var safetyApplied: Bool

    public init(
        summary: String,
        keyFindings: [String] = [],
        actionableNudges: [String] = [],
        confidence: Float = 0,
        safetyApplied: Bool = false
    ) {
        self.summary = summary
        self.keyFindings = keyFindings
        self.actionableNudges = actionableNudges
        self.confidence = confidence
        self.safetyApplied = safetyApplied
    }
}
