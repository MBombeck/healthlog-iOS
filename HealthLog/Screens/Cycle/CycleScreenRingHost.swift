#if DEBUG
    import SwiftUI

    /// **DEBUG-only in-situ preview of the cycle hero ring in its real chrome.**
    ///
    /// Reproduces the EXACT container chrome of ``CycleScreen/content(store:)``
    /// (the same `ScrollView` + `LazyVStack` + horizontal/top/bottom padding) and
    /// of ``CycleScreen/heroSection(store:)`` (the same `HLCycleRing` frame chain),
    /// so the hero can be eyeballed in its real layout context — NOT in an
    /// isolated square. This is the surface where the octagon-clip regression
    /// (the `geometryGroup` `drawingGroup` rasterising at the inset `side` instead
    /// of the full halo canvas) was caught + fixed: a clip in the container shows
    /// here where a bare-ring preview wouldn't. Confirm the full circle + halo
    /// render uncut on all four sides.
    ///
    /// NOTE: the SwiftUI canvas renders via `ImageRenderer`, which does NOT
    /// reproduce the Metal `drawingGroup` clip — to verify the clip is gone on the
    /// Metal path, render this body on the simulator (a throwaway UI-test host or
    /// the live `CycleScreen`).
    struct CycleScreenRingHostPreview: View {
        /// Representative mid-luteal model — "in 11 Tagen", Zyklustag 18, with
        /// the full four-phase arc set + ovulation marker + fertile band so the
        /// glow/halo render at their largest outward reach.
        static let model = HLCycleRing.Model(
            cycleLengthDays: 28,
            dayOfCycle: 18,
            segments: [
                .init(phase: .menstrual, dayRange: 1 ... 5),
                .init(phase: .follicular, dayRange: 6 ... 12),
                .init(phase: .ovulatory, dayRange: 13 ... 15),
                .init(phase: .luteal, dayRange: 16 ... 28)
            ],
            predictedOvulationDay: 14,
            fertileWindow: 12 ... 16,
            centerTitle: "in 11 Tagen",
            centerSubtitle: "Zyklustag 18"
        )

        let colorScheme: ColorScheme

        init(colorScheme: ColorScheme = .light) {
            self.colorScheme = colorScheme
        }

        var body: some View {
            // Mirror CycleScreen.content(store:) chrome 1:1.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HLSpace.xxl) {
                    hero
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.md)
                .padding(.bottom, HLSpace.xl)
            }
            .scrollContentBackground(.hidden)
            .background(HLSurface.primary)
            .preferredColorScheme(colorScheme)
        }

        /// Mirror CycleScreen.heroSection(store:) frame chain 1:1.
        private var hero: some View {
            HLCycleRing(
                model: Self.model,
                motion: .breathe,
                glow: .standard,
                accessibilityLabel: "cycle.home.title",
                accessibilityValue: "\(Self.model.centerTitle), \(Self.model.centerSubtitle)"
            )
            .frame(maxWidth: 360)
            .frame(height: 360)
            .frame(maxWidth: .infinity)
        }
    }

    #Preview("CycleScreen hero in-situ · Dark") {
        CycleScreenRingHostPreview()
            .preferredColorScheme(.dark)
    }

    #Preview("CycleScreen hero in-situ · Light") {
        CycleScreenRingHostPreview()
            .preferredColorScheme(.light)
    }
#endif
