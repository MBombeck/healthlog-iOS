import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// v0.5.5.6 POLISH-PR — share-sheet image rendering.
///
/// Wraps `ImageRenderer` (iOS 16+) so the screen can synthesise a
/// shareable PNG of a record card to drop into the system share-sheet.
/// Used by the Hero card's share button and each `RecordCard`'s
/// context-menu "Teilen" action.
///
/// **Pattern** — renders an off-screen `RecordShareImage.Surface`
/// (1080×1080 1:1 square, the safest Instagram/X aspect), captures via
/// `ImageRenderer`, hands the UIImage off to a `UIActivityViewController`
/// wrapped in `UIViewControllerRepresentable`.
///
/// **Why a square**: 1:1 is the only aspect that lands cleanly on every
/// social channel (Instagram, X, Threads, WhatsApp status) without
/// cropping. Operators don't have to worry about which platform they're
/// sharing to.
enum RecordShareImage {
    // Fixed pixel fonts are CORRECT inside `Surface` (audit-01 M1): it renders
    // onto a fixed 1080×1080 export canvas via `ImageRenderer` — Dynamic Type
    // has no meaning for a share PNG and scaling would break the composition.
    // swiftlint:disable dynamic_type_bypass

    /// Off-screen view rendered into a UIImage for sharing.
    struct Surface: View {
        let record: PersonalRecord

        var body: some View {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: tint, location: 0.0),
                        .init(color: tint.opacity(0.4), location: 0.55),
                        .init(color: HLColor.recordHeroScrim.opacity(0.92), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Image(systemName: "rosette")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(HLColor.recordHeroInk)
                        Text(verbatim: "HealthLog")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(HLColor.recordHeroInk.opacity(0.85))
                        Spacer()
                    }
                    Spacer(minLength: 0)
                    Text(metricLabel.uppercased())
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(HLColor.recordHeroInk.opacity(0.85))
                    Text(formattedValue)
                        .font(.system(size: 140, weight: .bold, design: .rounded))
                        .foregroundStyle(HLColor.recordHeroInk)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(record.base.unit)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(HLColor.recordHeroInk.opacity(0.85))
                    Spacer(minLength: 0)
                    Text("Personal record · \(dateLabel)")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(HLColor.recordHeroInk.opacity(0.85))
                }
                .padding(64)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 1080, height: 1080)
            .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        }

        private var tint: Color {
            PersonalRecordKindTint.color(for: record.kind)
        }

        private var metricLabel: String {
            if let slot = record.base.metricSlot, !slot.isEmpty { return slot }
            return MetricTypeLocalisation.label(forType: record.base.metricType)
        }

        private var formattedValue: String {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.numberStyle = .decimal
            f.maximumFractionDigits = 1
            f.minimumFractionDigits = 0
            return f.string(from: NSNumber(value: record.base.value)) ?? "\(record.base.value)"
        }

        private var dateLabel: String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.dateStyle = .long
            return f.string(from: record.base.achievedAt)
        }
    }

    // swiftlint:enable dynamic_type_bypass

    /// Render the surface to a `UIImage`. Returns `nil` on platforms
    /// without UIKit (mac unit-tests) so callers can short-circuit
    /// gracefully.
    @MainActor
    static func render(_ record: PersonalRecord) -> UIImage? {
        #if canImport(UIKit)
            let renderer = ImageRenderer(content: Surface(record: record))
            // `UIScreen.main` is deprecated (no single main screen in iOS 18
            // multi-scene). `UITraitCollection.current.displayScale` reflects the
            // active scene's scale on the main actor, so the exported PNG keeps the
            // same device-scale resolution (1080 × displayScale) as before.
            renderer.scale = UITraitCollection.current.displayScale
            return renderer.uiImage
        #else
            return nil
        #endif
    }
}

#if canImport(UIKit)
    /// Bridge to `UIActivityViewController` so SwiftUI can present the
    /// system share sheet with a pre-rendered image. Wraps the result
    /// of `RecordShareImage.render(...)`.
    struct RecordShareSheet: UIViewControllerRepresentable {
        let image: UIImage
        let onComplete: () -> Void

        func makeUIViewController(context: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(
                activityItems: [image],
                applicationActivities: nil
            )
            controller.completionWithItemsHandler = { _, _, _, _ in
                onComplete()
            }
            return controller
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }
#endif
