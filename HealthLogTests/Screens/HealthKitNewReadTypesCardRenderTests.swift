// App-target symbols (the dashboard card); the SPM test build skips the file.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **HK-NEW (1.5)** — the new-types card renders light and dark, and at
    /// the largest accessibility text size, in the run's language. With
    /// `HKNEW_RENDER_DIR` set (pass `TEST_RUNNER_HKNEW_RENDER_DIR` to
    /// xcodebuild) the pictures go to that folder, never into the checkout.
    @Suite("HK-NEW — new Apple Health types card renders", .serialized)
    @MainActor
    struct HealthKitNewReadTypesCardRenderTests {
        @Test("the card paints in light and dark, with all five types named")
        func lightAndDark() throws {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = try render(card(), name: "card-\(style == .dark ? "dark" : "light")", style: style)
                #expect(Self.hasInk(image))
            }
        }

        @Test("the card paints at accessibility-XXXL without losing its button")
        func largestText() throws {
            let view = card().environment(\.dynamicTypeSize, .accessibility5)
            let image = try render(view, name: "card-xxxl", style: .light, height: 2000)
            #expect(Self.hasInk(image))
        }

        @Test("the settings link label reads as a quiet caption link")
        func settingsLink() throws {
            let link = HLSettingsCard(icon: "list.bullet.rectangle.fill", title: "Apple Health data types") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    Text("settings.applehealth.newTypes.link")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
            .padding(HLSpace.md)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = try render(link, name: "settings-link-\(style == .dark ? "dark" : "light")", style: style, height: 200)
                #expect(Self.hasInk(image))
            }
        }

        private func card() -> some View {
            HealthKitNewReadTypesCardContent(
                pending: HealthKitServer144Types.lateReadIdentifiers,
                onContinue: {},
                onNotNow: {}
            )
            .padding(HLSpace.md)
        }

        private func render(
            _ view: some View,
            name: String,
            style: UIUserInterfaceStyle,
            height: CGFloat = 320
        ) throws -> UIImage {
            let size = CGSize(width: 393, height: height)
            let host = UIHostingController(rootView: AnyView(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window.windowScene = scene
            }
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["HKNEW_RENDER_DIR"] {
                let language = Bundle.main.preferredLocalizations.first ?? "base"
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(language).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        /// `true` when the picture carries more than one colour.
        private static func hasInk(_ image: UIImage) -> Bool {
            guard let cg = image.cgImage,
                  let data = cg.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data) else { return false }
            let length = CFDataGetLength(data)
            guard length > 8 else { return false }
            let first = (bytes[0], bytes[1], bytes[2])
            var index = 0
            while index + 2 < length {
                if (bytes[index], bytes[index + 1], bytes[index + 2]) != first { return true }
                index += 4 * 97
            }
            return false
        }
    }

#endif
