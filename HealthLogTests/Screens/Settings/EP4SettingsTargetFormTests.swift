import SwiftUI
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UIKit

    /// The settings area on the shared forms: a row that leaves the app says
    /// so with the one external sign at its trailing edge, and an explanation
    /// in onboarding wraps instead of ending in "…".
    @Suite("E-P4 Einstellungen und Mehr: Zielformen")
    @MainActor
    struct EP4SettingsTargetFormTests {
        typealias Action = NotificationDiagnosticsScreen.AuthorizationAction

        @Test("leaving for the system settings carries the external sign; the prompt stays in the app")
        func authorizationActionSigns() {
            #expect(Action.deepLinkSettings.presents == .external)
            #expect(Action.requestPrompt.presents == .confirm)
            #expect(Action.deepLinkSettings.symbol != "arrow.up.right.square")
            #expect(
                HLSettingsActionRow<EmptyView, EmptyView>.trailingSymbol(for: Action.deepLinkSettings.presents)
                    == HLRowIndicator.externalSymbol
            )
            #expect(HLSettingsActionRow<EmptyView, EmptyView>.trailingSymbol(for: Action.requestPrompt.presents) == nil)
        }

        @Test("an onboarding explanation wraps at the standard size instead of being cut")
        func explanationWraps() {
            let short = OnboardingExplainRow(symbol: "lock.shield.fill", title: "Daten", subtitle: "Kurz.")
            let long = OnboardingExplainRow(
                symbol: "lock.shield.fill",
                title: "Daten",
                subtitle: String(repeating: "Auf deinem eigenen Server, nie auf einer fremden Cloud. ", count: 3)
            )
            #expect(height(of: long) > height(of: short) + 20)
        }

        @Test("the explanation row keeps the symbol column of every other row")
        func explanationSymbolColumn() {
            let withSymbol = OnboardingExplainRow(symbol: "bell.fill", title: "Titel", subtitle: "Text")
            let bareTitle = HLRowTitle(Text(verbatim: "Titel"))
            let column = HLRowGlyph.columnWidth(forScaled: HLSettingsIconChip.baseSide)
            #expect(width(of: withSymbol) >= width(of: bareTitle) + column)
        }

        private func height(of view: some View) -> CGFloat {
            fitting(view, width: 300).height
        }

        private func width(of view: some View) -> CGFloat {
            fitting(view.fixedSize(), width: 2000).width
        }

        private func fitting(_ view: some View, width: CGFloat) -> CGSize {
            let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, .large)))
            host.safeAreaRegions = []
            return host.sizeThatFits(in: CGSize(width: width, height: 4000))
        }
    }
#endif
