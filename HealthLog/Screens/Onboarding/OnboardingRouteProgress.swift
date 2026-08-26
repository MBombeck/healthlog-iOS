import Foundation

// **Phase 08 Plan 10 — the progress a route produces, rather than the progress
// somebody typed.**
//
// The indicator used to read a ten-case table of hand-tuned fractions
// (`0.18`, `0.32`, `0.5`, …) and a label table that named counts no branch ever
// had: "Schritt 4 von 6: Anmelden" on a server route with eight steps, spoken
// to a standalone user who walks five. Both tables were `private var` on the
// `View`, so nothing but a human could check either.
//
// This lives beside `OnboardingFlow` rather than inside it for the reason
// `PostAuthenticationRouteSteps.swift` does: that file is already over the
// 600-line budget, and a value derived from an array of steps has no reason to
// share a view's scope.

extension OnboardingFlow {
    /// Where the user is in the route they are actually walking.
    ///
    /// Every term is derived from the ordered route: the denominator is its
    /// length, the numerator is the position of the visible step *in it*, and
    /// the fraction is their quotient. A step a branch never shows is not in
    /// the array, so it is neither counted nor reserved — which is the whole
    /// difference between this and the fraction table it replaces.
    struct RouteProgress: Equatable, Sendable {
        /// 1-based position of the visible step in the active route.
        let position: Int
        /// The number of steps this branch actually walks.
        let total: Int
        /// `0…1`, derived — never a constant.
        let fraction: Double
        /// What the step is, spoken. Names the step and never a count, because
        /// a count baked into a translation cannot follow a branch.
        let label: String
        /// Where in the route it sits, spoken and localized.
        let value: String

        init(step: OnboardingFlow.Step, in route: [OnboardingFlow.Step]) {
            let anchored = Self.anchor(for: step, in: route)
            let index = anchored.flatMap { route.firstIndex(of: $0) }
            total = route.count
            position = (index ?? 0) + 1
            fraction = total > 0 ? Double(position) / Double(total) : 0
            label = Self.label(for: step)
            value = String(
                format: String(localized: "onboarding.progress.position"),
                position,
                total
            )
        }

        /// The route position a step stands on.
        ///
        /// Three steps are not route positions of their own. The two
        /// post-authentication lookup surfaces sit *between* the login and the
        /// optional tail — the route beyond them is not known until they
        /// resolve — so they stand where the login left the user. The terminal
        /// handoff stands on the last step of the route it finished.
        private static func anchor(
            for step: OnboardingFlow.Step,
            in route: [OnboardingFlow.Step]
        ) -> OnboardingFlow.Step? {
            switch step {
            case .checkingCompletion, .completionUnavailable:
                route.contains(.auth) ? .auth : route.first
            case .done:
                route.last
            default:
                route.contains(step) ? step : route.first
            }
        }

        private static func label(for step: OnboardingFlow.Step) -> String {
            switch step {
            case .welcome: String(localized: "onboarding.progress.welcome")
            case .mode: String(localized: "onboarding.progress.mode")
            case .serverURL: String(localized: "onboarding.progress.serverURL")
            case .auth: String(localized: "onboarding.progress.auth")
            case .checkingCompletion: String(localized: "onboarding.progress.checkingCompletion")
            case .completionUnavailable: String(localized: "onboarding.progress.completionUnavailable")
            case .healthKit: String(localized: "onboarding.progress.healthKit")
            case .notifications: String(localized: "onboarding.progress.notifications")
            case .aiSource: String(localized: "onboarding.progress.aiSource")
            case .anamnesis: String(localized: "onboarding.progress.anamnesis")
            case .baselineProfile: String(localized: "onboarding.progress.baselineProfile")
            case .done: String(localized: "Done")
            }
        }
    }
}
