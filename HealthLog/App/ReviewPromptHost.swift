import StoreKit
import SwiftUI
import UIKit

/// Builds is-this-the-demo from the server address and the launch.
enum ReviewPromptEnvironment {
    /// The public demo, UI tests, and unit tests never ask for a review.
    static func isDemo(baseURL: URL?, arguments: [String], environment: [String: String]) -> Bool {
        if let baseURL, AppEnvironment.inferRegion(for: baseURL) == .demo { return true }
        if arguments.contains(where: { $0.hasPrefix("-uitest") }) { return true }
        return environment["XCTestConfigurationFilePath"] != nil
    }

    /// Whether the selected tab shows its root page, from the router where the
    /// tab keeps its path there. `nil` when the router does not know.
    @MainActor
    static func routerSaysRoot(tab: AuthenticatedShell.TabIdentifier, router: AppRouter) -> Bool? {
        switch tab {
        case .home: router.homePath.isEmpty
        case .meds: router.medsPath.isEmpty
        case .more: router.morePath.isEmpty
        case let .section(destination): router.sectionPath(destination).isEmpty
        case .measure: false
        case .insights: nil
        }
    }
}

/// Reads what SwiftUI does not expose: anything presented over the shell, and
/// how deep the selected tab's navigation stack is.
@MainActor
enum ReviewPromptWindowProbe {
    static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
    }

    /// A sheet, cover, alert, or dialog is up.
    static func hasPresentation(_ root: UIViewController?) -> Bool {
        root?.presentedViewController != nil
    }

    /// `true` when the selected tab's stack shows its first page, `nil` when
    /// no stack is found.
    static func selectedStackIsAtRoot(_ root: UIViewController?) -> Bool? {
        guard let tabs = first(UITabBarController.self, under: root),
              let navigation = first(UINavigationController.self, under: tabs.selectedViewController) else { return nil }
        return navigation.viewControllers.count <= 1
    }

    private static func first<T: UIViewController>(_: T.Type, under root: UIViewController?) -> T? {
        var queue = root.map { [$0] } ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let match = next as? T { return match }
            queue.append(contentsOf: next.children)
        }
        return nil
    }
}

/// **Shows the App Store review prompt at a calm moment.**
///
/// Waits for a request from ``ReviewPromptCoordinator``, then for the user to
/// be back on a tab root of the active app with nothing presented and no
/// banner up, twice in a row a short while apart so the dialog never lands in
/// a dismiss animation. If the app leaves the foreground, the wait pauses and
/// the request stays; it resumes when the app is active again. After a minute
/// of the user staying busy in the active app it gives the request up; the
/// next recorded value asks again.
struct ReviewPromptHost: ViewModifier {
    @Environment(\.appContainer) private var container
    @Environment(AppRouter.self) private var router
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    /// The shell's "intake queued" banner, which is shell state, not a
    /// presented controller.
    @Binding var queuedBannerAt: Date?
    var coordinator: ReviewPromptCoordinator = .live

    private static let settle: Duration = .milliseconds(1500)
    private static let attempts = 40

    private struct WaitKey: Equatable {
        let request: Int
        let active: Bool
    }

    func body(content: Content) -> some View {
        content
            .task { container?.wireReviewPrompt(coordinator) }
            .task(id: WaitKey(request: coordinator.promptRequest, active: scenePhase == .active)) {
                guard coordinator.hasPendingRequest, scenePhase == .active else { return }
                await waitForCalmMoment()
            }
    }

    private func waitForCalmMoment() async {
        var wasCalm = false
        for _ in 0 ..< Self.attempts {
            do { try await Task.sleep(for: Self.settle) } catch { return }
            guard coordinator.hasPendingRequest else { return }
            let moment = await currentObservation().moment
            switch ReviewPromptPolicy.waitStep(moment, wasCalm: wasCalm) {
            case .prompt:
                // A calm moment the pacing still refuses ends the request too.
                if coordinator.promptNow(moment: moment) != nil { requestReview() } else { coordinator.dropRequest() }
                return
            case .suspend:
                // Background or inactive: keep the request for the next activation.
                return
            case let .wait(calm):
                wasCalm = calm
            }
        }
        coordinator.dropRequest()
    }

    private func currentObservation() async -> ReviewPromptObservation {
        let root = ReviewPromptWindowProbe.rootViewController()
        let interfaceUp = await container?.reachability.isCurrentlyOnline() ?? false
        var serverAnswers = false
        if interfaceUp { serverAnswers = await container?.reachability.confirmedReachable() ?? false }
        return ReviewPromptObservation(
            hasActiveScene: root != nil,
            scenePhaseIsActive: scenePhase == .active,
            hasPresentation: ReviewPromptWindowProbe.hasPresentation(root),
            routerSaysRoot: ReviewPromptEnvironment.routerSaysRoot(tab: router.selectedTab, router: router),
            stackIsAtRoot: ReviewPromptWindowProbe.selectedStackIsAtRoot(root),
            interfaceUp: interfaceUp,
            serverAnswers: serverAnswers,
            isDemo: ReviewPromptEnvironment.isDemo(
                baseURL: container?.environment.baseURL,
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            ),
            hasOverlay: queuedBannerAt != nil || container?.undoCoordinator.current != nil
        )
    }
}

extension View {
    /// Hosts the review prompt; attach once, on the authenticated shell.
    func reviewPromptHost(queuedBannerAt: Binding<Date?>) -> some View {
        modifier(ReviewPromptHost(queuedBannerAt: queuedBannerAt))
    }
}
