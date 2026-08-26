import Foundation

/// 22-01 (R4) — what the Insights strip says while availability is unresolved.
///
/// R4-ANSWER row 6 settled what was NOT happening: `isInitialSkeletonVisible`
/// gates the Insights overview BODY, never the tab strip, and for an operator
/// with mood entries it was not raised in b266 either. So the strip never wore
/// a skeleton — it simply rendered a short list and said nothing about it, and
/// a short list that says nothing is indistinguishable from a complete one.
///
/// b266 answered that shape with a silhouette (a lie: it claims the missing
/// sections are moments away) and b267 with silence (a different lie: it
/// claims there is nothing more). This is the third answer: one quiet line of
/// prose, and only in the case where the strip genuinely knows nothing.
///
/// Deliberately a pure mapping over view-owned state. `MeasurementsStore` sits
/// against the frozen Phase-06 effect census and publishes nothing new for
/// this; the container derives the resolution from its own `.task`'s await and
/// from whether the latch holds any kind at all.
enum InsightsAvailabilityStatement {
    /// Where the container's availability read stands, as the VIEW sees it.
    enum Resolution: Sendable, Equatable {
        /// The read has not returned yet.
        case pending
        /// The read returned and the strip has kinds to show.
        case resolved
        /// The read PUBLISHED nothing: refused, failed, or interrupted. Not
        /// the same as "found nothing" — an account with no measurements
        /// publishes an honest empty answer and resolves. 22-02's accessibility
        /// gate is why the difference is drawn here rather than inferred from an
        /// empty set: inferred, the statement became permanent for every
        /// measurement-less account and cost the overview its layout.
        case unresolved
    }

    /// The one-liners this surface may show. The raw value IS the catalogue key.
    enum Statement: String, Sendable, Equatable, CaseIterable {
        case loading = "insights.availability.loading"
        case unavailable = "insights.availability.unavailable"

        var text: String {
            switch self {
            case .loading: String(localized: "insights.availability.loading")
            case .unavailable: String(localized: "insights.availability.unavailable")
            }
        }
    }

    /// The mapping. `nil` means "say nothing" — the strip shows what it knows.
    static func statement(
        for resolution: Resolution,
        latchedKindsAreEmpty: Bool
    ) -> Statement? {
        // The latch is the stronger signal: the moment the strip holds ANY kind
        // it has something true to show, and a line of prose over live pills
        // would be noise rather than honesty.
        guard latchedKindsAreEmpty else { return nil }
        return switch resolution {
        case .pending: .loading
        case .unresolved: .unavailable
        // A read that resolved is an account with no measurements, not a
        // failure — and it gets no commentary at all.
        case .resolved: nil
        }
    }

    /// The localized line, or `nil` when the strip has nothing to add.
    static func text(
        for resolution: Resolution,
        latchedKindsAreEmpty: Bool
    ) -> String? {
        statement(for: resolution, latchedKindsAreEmpty: latchedKindsAreEmpty)?.text
    }
}
