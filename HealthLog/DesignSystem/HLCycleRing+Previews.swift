import SwiftUI

// MARK: - HLCycleRing preview gallery (DEBUG-only, split out for file-length budget)

#if DEBUG
    /// Sample models for the preview gallery (preview-only strings — German +
    /// English — the component itself is string-injection driven and owns none).
    private enum HLCycleRingPreviewData {
        static let standardSegments: [HLCycleRing.Model.Segment] = [
            .init(phase: .menstrual, dayRange: 1 ... 5),
            .init(phase: .follicular, dayRange: 6 ... 12),
            .init(phase: .ovulatory, dayRange: 13 ... 16),
            .init(phase: .luteal, dayRange: 17 ... 28)
        ]

        /// Mid-luteal — "Period in 5 days" (German centre strings).
        static let midLuteal = HLCycleRing.Model(
            cycleLengthDays: 28,
            dayOfCycle: 23,
            segments: standardSegments,
            predictedOvulationDay: 14,
            fertileWindow: 12 ... 16,
            centerTitle: "in 5 Tagen",
            centerSubtitle: "Periode · Zyklustag 23"
        )

        /// Menstrual day 2 (English centre strings).
        static let menstrualDay2 = HLCycleRing.Model(
            cycleLengthDays: 28,
            dayOfCycle: 2,
            segments: standardSegments,
            predictedOvulationDay: 14,
            fertileWindow: nil,
            centerTitle: "Day 2",
            centerSubtitle: "Period · light flow"
        )

        /// Ovulatory peak (German, with fertile window).
        static let ovulatoryPeak = HLCycleRing.Model(
            cycleLengthDays: 28,
            dayOfCycle: 14,
            segments: standardSegments,
            predictedOvulationDay: 14,
            fertileWindow: 12 ... 16,
            centerTitle: "Eisprung heute",
            centerSubtitle: "Fruchtbar · Zyklustag 14"
        )

        /// Still-learning — sparse, one coarse segment, no fertile window.
        static let stillLearning = HLCycleRing.Model(
            cycleLengthDays: 30,
            dayOfCycle: 9,
            segments: [.init(phase: .follicular, dayRange: 1 ... 30)],
            predictedOvulationDay: nil,
            fertileWindow: nil,
            centerTitle: "Lerne noch",
            centerSubtitle: "Mehr Zyklen für eine Prognose"
        )
    }

    private struct HLCycleRingPreviewTile: View {
        let title: String
        let model: HLCycleRing.Model
        var motion: HLCycleRing.Motion = .breathe
        var glow: HLCycleRing.Glow = .standard
        var ambiance: HLCycleRing.Ambiance = .off

        var body: some View {
            VStack(spacing: HLSpace.sm) {
                HLCycleRing(
                    model: model,
                    motion: motion,
                    glow: glow,
                    ambiance: ambiance,
                    accessibilityLabel: "Cycle ring",
                    accessibilityValue: "\(model.centerTitle), \(model.centerSubtitle)"
                )
                .frame(width: 220, height: 220)
                Text(title)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }

    #Preview("States · Light") {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.xxl) {
                HLCycleRingPreviewTile(title: "Mid-luteal (in 5 Tagen)", model: HLCycleRingPreviewData.midLuteal)
                HLCycleRingPreviewTile(title: "Menstrual day 2", model: HLCycleRingPreviewData.menstrualDay2)
                HLCycleRingPreviewTile(title: "Ovulatory peak", model: HLCycleRingPreviewData.ovulatoryPeak)
                HLCycleRingPreviewTile(title: "Still learning", model: HLCycleRingPreviewData.stillLearning)
            }
            .padding(HLSpace.xxl)
        }
        .background(HLSurface.primary)
        .preferredColorScheme(.light)
    }

    #Preview("States · Dark") {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.xxl) {
                HLCycleRingPreviewTile(title: "Mid-luteal (in 5 Tagen)", model: HLCycleRingPreviewData.midLuteal)
                HLCycleRingPreviewTile(title: "Menstrual day 2", model: HLCycleRingPreviewData.menstrualDay2)
                HLCycleRingPreviewTile(title: "Ovulatory peak", model: HLCycleRingPreviewData.ovulatoryPeak)
                HLCycleRingPreviewTile(title: "Still learning", model: HLCycleRingPreviewData.stillLearning)
            }
            .padding(HLSpace.xxl)
        }
        .background(HLSurface.primary)
        .preferredColorScheme(.dark)
    }

    #Preview("Motion variants · Dark") {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.xxl) {
                HLCycleRingPreviewTile(title: "breathe", model: HLCycleRingPreviewData.midLuteal, motion: .breathe)
                HLCycleRingPreviewTile(title: "tracer", model: HLCycleRingPreviewData.midLuteal, motion: .tracer)
                HLCycleRingPreviewTile(title: "sheen", model: HLCycleRingPreviewData.ovulatoryPeak, motion: .sheen)
                HLCycleRingPreviewTile(title: "none (static)", model: HLCycleRingPreviewData.ovulatoryPeak, motion: .none)
            }
            .padding(HLSpace.xxl)
        }
        .background(HLSurface.primary)
        .preferredColorScheme(.dark)
    }

    #Preview("Glow · Dark") {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.xxl) {
                HLCycleRingPreviewTile(
                    title: "Glow ON (standard)", model: HLCycleRingPreviewData.midLuteal, glow: .standard
                )
                HLCycleRingPreviewTile(
                    title: "Glow OFF", model: HLCycleRingPreviewData.midLuteal, glow: .off
                )
                HLCycleRingPreviewTile(
                    title: "Glow + mesh ambiance",
                    model: HLCycleRingPreviewData.midLuteal, glow: .standard, ambiance: .withMesh
                )
                HLCycleRingPreviewTile(
                    title: "Ovulation peak (sparkle)",
                    model: HLCycleRingPreviewData.ovulatoryPeak, glow: .standard
                )
            }
            .padding(HLSpace.xxl)
        }
        .background(HLSurface.primary)
        .preferredColorScheme(.dark)
    }

    #Preview("Glow · Light") {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.xxl) {
                HLCycleRingPreviewTile(
                    title: "Glow ON (standard)", model: HLCycleRingPreviewData.midLuteal, glow: .standard
                )
                HLCycleRingPreviewTile(
                    title: "Glow OFF", model: HLCycleRingPreviewData.midLuteal, glow: .off
                )
                HLCycleRingPreviewTile(
                    title: "Glow + mesh ambiance",
                    model: HLCycleRingPreviewData.midLuteal, glow: .standard, ambiance: .withMesh
                )
                HLCycleRingPreviewTile(
                    title: "Ovulation peak (sparkle)",
                    model: HLCycleRingPreviewData.ovulatoryPeak, glow: .standard
                )
            }
            .padding(HLSpace.xxl)
        }
        .background(HLSurface.primary)
        .preferredColorScheme(.light)
    }
#endif
