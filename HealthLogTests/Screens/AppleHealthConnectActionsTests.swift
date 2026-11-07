// App-target symbols (`HKReadinessStore`, the settings views); the SPM test
// build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **#154 (MIRROR, 1.5)** — the Apple Health card said "Connected" in
    /// its pill and "Connect to Apple Health" on its primary button whenever a
    /// write type was missing. Now it offers one action per state.
    ///
    /// (e) the three states as a test and, with `MIRROR_RENDER_DIR` set (pass
    /// `TEST_RUNNER_MIRROR_RENDER_DIR` to xcodebuild), as pictures light and
    /// dark in the run's language. Pictures go only to that folder, never into
    /// the checkout.
    @Suite("Apple Health card: one action per state (#154)", .serialized)
    @MainActor
    struct AppleHealthConnectActionsTests {
        typealias Action = HKReadinessStore.ConnectionAction

        // MARK: - The derivation

        @Test("the dialog is unanswered: the primary Connect button, whatever else is true")
        func unansweredDialogConnects() {
            #expect(HKReadinessStore.connectionAction(state: .notRequested, isConnected: false, sheetAnswered: false)
                == .connect)
            // New types after an update leave the dialog unanswered again.
            #expect(HKReadinessStore.connectionAction(
                state: .partiallyGranted(missing: ["HKQuantityTypeIdentifierBodyMass"]),
                isConnected: true,
                sheetAnswered: false
            ) == .connect)
        }

        @Test("receiving with write types missing (the reported case): no Connect, a review link")
        func receivingWithMissingWritesReviews() {
            let missing = HKReadinessStore.ConnectionState.partiallyGranted(missing: ["HKQuantityTypeIdentifierBodyMass"])
            #expect(HKReadinessStore.connectionAction(state: missing, isConnected: true, sheetAnswered: true)
                == .reviewWriteAccess)
            #expect(HKReadinessStore.connectionAction(state: missing, isConnected: true, sheetAnswered: nil)
                == .reviewWriteAccess)
            // Every write declined, but data demonstrably arrives.
            #expect(HKReadinessStore.connectionAction(state: .denied, isConnected: true, sheetAnswered: true)
                == .reviewWriteAccess)
        }

        @Test("declined and nothing arrived: opening Apple Health is the primary button")
        func declinedOpensHealth() {
            #expect(HKReadinessStore.connectionAction(state: .denied, isConnected: false, sheetAnswered: true)
                == .openHealthApp)
            #expect(HKReadinessStore.connectionAction(state: .denied, isConnected: false, sheetAnswered: nil)
                == .openHealthApp)
        }

        @Test("all granted or not yet known: no action")
        func grantedOrUnknownHasNoAction() {
            for answered in [true, false, nil] as [Bool?] {
                #expect(HKReadinessStore.connectionAction(state: .fullyGranted, isConnected: true, sheetAnswered: answered)
                    == .none)
                #expect(HKReadinessStore.connectionAction(state: .unknown, isConnected: false, sheetAnswered: answered)
                    == .none)
            }
        }

        @Test("when the platform cannot say, the 1.4 rule stands for a card without proof of receiving")
        func unknownSheetFallsBack() {
            #expect(HKReadinessStore.connectionAction(state: .notRequested, isConnected: false, sheetAnswered: nil)
                == .connect)
            #expect(HKReadinessStore.connectionAction(
                state: .partiallyGranted(missing: ["x"]),
                isConnected: false,
                sheetAnswered: nil
            ) == .connect)
        }

        // MARK: - (e) The three states, rendered

        @Test("(e) each state paints exactly its own action", arguments: [
            ("connect", Action.connect),
            ("review", Action.reviewWriteAccess),
            ("declined", Action.openHealthApp)
        ])
        func eachStateRenders(name: String, action: Action) throws {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = try render(card(action), name: "after-\(name)-\(Self.styleName(style))", style: style)
                #expect(Self.hasInk(image), "\(name) rendered blank")
            }
        }

        @Test("(e) before: the reported state showed Connect and Open next to Connected")
        func beforePicture() throws {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let image = try render(beforeCard, name: "before-review-\(Self.styleName(style))", style: style)
                #expect(Self.hasInk(image))
            }
        }

        // MARK: - Rendering

        /// The connection card as the screen builds it, minus the live pill.
        private func card(_ action: Action) -> some View {
            HLSettingsCard(icon: "heart.text.square.fill", title: "Apple Health") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    caption
                    if action == .reviewWriteAccess {
                        notice
                    }
                    AppleHealthConnectActions(action: action, connect: {})
                    HLButton(
                        String(localized: "Sync now"),
                        icon: "arrow.triangle.2.circlepath",
                        variant: .secondary,
                        size: .regular
                    ) {}
                }
            }
            .padding(HLSpace.md)
        }

        /// What 1.4.1 showed in the reported state (#154).
        private var beforeCard: some View {
            HLSettingsCard(icon: "heart.text.square.fill", title: "Apple Health") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    caption
                    notice
                    HLButton(String(localized: "Connect to Apple Health"), icon: "heart.fill", variant: .primary) {}
                    HLButton(
                        String(localized: "Open in Apple Health"),
                        icon: "arrow.up.right.square",
                        variant: .secondary,
                        size: .regular
                    ) {}
                    HLButton(
                        String(localized: "Sync now"),
                        icon: "arrow.triangle.2.circlepath",
                        variant: .secondary,
                        size: .regular
                    ) {}
                }
            }
            .padding(HLSpace.md)
        }

        private var caption: some View {
            Text(String(localized: "Not synced yet"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }

        private var notice: some View {
            HStack(alignment: .top, spacing: HLSpace.xs) {
                Image(systemName: "arrow.up.forward.circle")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                Text("settings.applehealth.writeback.limited")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func render(_ view: some View, name: String, style: UIUserInterfaceStyle) throws -> UIImage {
            let size = CGSize(width: 393, height: 420)
            let host = UIHostingController(rootView: AnyView(view.frame(maxWidth: .infinity, alignment: .top)))
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
            if let dir = ProcessInfo.processInfo.environment["MIRROR_RENDER_DIR"] {
                let language = Bundle.main.preferredLocalizations.first ?? "base"
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(language).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        private static func styleName(_ style: UIUserInterfaceStyle) -> String {
            style == .dark ? "dark" : "light"
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
