import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// **v0.14.x Q — Home-Screen Quick Actions (`UIApplicationShortcutItem`).**
///
/// A long-press on the app icon offers the three capture entry points the app
/// already exposes through the central `CapturePicker` and the `OpenCaptureIntent`
/// control: log a measurement, log a medication intake, log a mood. Each Quick
/// Action reuses the SAME one-shot hand-off the Control-Center "Erfassen" control
/// uses (`CaptureRequestStore`): the app-delegate writes a marker keyed to the
/// chosen ``CaptureRequestStore/Surface``, and `RootView`'s existing
/// `consumePendingCaptureRequestIfAuthenticated()` picks it up on the next
/// foreground / launch tick and routes via `AppRouter`. This keeps a single
/// capture-entry code path whether the surface is reached from the picker, a
/// control, a notification, or a Home-Screen shortcut — and it deep-links
/// correctly from a cold launch (the marker survives the launch the shortcut
/// triggered, and the consume runs once the auth bootstrap promotes the phase).
///
/// **Why the marker hand-off, not the `AppRouter` directly?** The shortcut
/// callback fires in the UIKit app-delegate, before the SwiftUI environment /
/// composition root is reachable, and possibly during a cold launch where
/// `AppRouter` doesn't exist yet. The marker file is the established, testable
/// seam for exactly this "UIKit edge → app consumes on foreground" shape.
enum HLQuickAction: String, CaseIterable {
    case measurement
    case medication
    case mood

    /// Reverse-DNS shortcut-item type strings. Stable identifiers UIKit passes
    /// back in the `performActionFor` callback — must not change once shipped
    /// (a renamed type silently breaks an existing pinned shortcut).
    var shortcutType: String {
        "dev.healthlog.app.quickaction.\(rawValue)"
    }

    /// Resolve a UIKit shortcut-item type back to its action. `nil` for an
    /// unknown type (e.g. a stale shortcut from a future build) so the caller
    /// can safely ignore it.
    init?(shortcutType: String) {
        let prefix = "dev.healthlog.app.quickaction."
        guard shortcutType.hasPrefix(prefix) else { return nil }
        let raw = String(shortcutType.dropFirst(prefix.count))
        self.init(rawValue: raw)
    }

    /// The capture surface this action hands off to. Pure mapping — the unit
    /// of behaviour the test pins so a regression that crosses the wires
    /// (medication → mood etc.) fails the build.
    var captureSurface: CaptureRequestStore.Surface {
        switch self {
        case .measurement: .capture
        case .medication: .medication
        case .mood: .mood
        }
    }

    /// SF Symbol matching the central `CapturePicker` row glyphs so the
    /// Home-Screen shortcut reads as the same affordance.
    var systemImageName: String {
        switch self {
        case .measurement: "plus.circle.fill"
        case .medication: "pills.fill"
        case .mood: "face.smiling"
        }
    }

    /// Localized shortcut title. Reuses the existing `CapturePicker` row title
    /// keys ("Log a measurement" / "Log an intake" / "Log your mood") so the
    /// shortcut wording stays in lockstep with the in-app picker and is never a
    /// hardcoded string. Resolved at registration time (UIKit shortcut items
    /// take a plain `String`, not a `LocalizedStringKey`).
    var localizedTitle: String {
        switch self {
        case .measurement: String(localized: "capture.picker.measurement.title")
        case .medication: String(localized: "capture.picker.medication.title")
        case .mood: String(localized: "capture.picker.mood.title")
        }
    }

    #if canImport(UIKit)
        /// The `UIApplicationShortcutItem` for this action.
        var shortcutItem: UIApplicationShortcutItem {
            UIApplicationShortcutItem(
                type: shortcutType,
                localizedTitle: localizedTitle,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: systemImageName),
                userInfo: nil
            )
        }
    #endif
}

#if canImport(UIKit)
    enum HLQuickActions {
        /// Register the three dynamic shortcut items on the running application.
        /// Idempotent — UIKit replaces the whole array each call. Called from the
        /// app-delegate launch path so the shortcuts are present on first
        /// long-press without waiting for a relevant data change.
        @MainActor
        static func register(on application: UIApplication = .shared) {
            application.shortcutItems = HLQuickAction.allCases.map(\.shortcutItem)
        }

        /// Handle a `performActionFor` callback: resolve the shortcut to its
        /// capture surface and drop a one-shot `CaptureRequestStore` marker the
        /// app consumes on its next foreground tick. Returns `true` when the
        /// shortcut was recognised + a marker was written, `false` for an
        /// unknown shortcut type (UIKit's `completionHandler` contract).
        @discardableResult
        static func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
            guard let action = HLQuickAction(shortcutType: shortcutItem.type) else {
                // The shortcut type is an operator-grade reverse-DNS identifier
                // (enum-shaped, no PII), so `.public` is the sanctioned use here.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.debug(
                    "Quick-Action übersprungen — unbekannter Typ: \(shortcutItem.type, privacy: .public)"
                )
                return false
            }
            do {
                try CaptureRequestStore().write(
                    CaptureRequestStore.Request(requestedAt: .now, surface: action.captureSurface)
                )
            } catch {
                // A write failure is logged + swallowed — the app still
                // foregrounds, just on its last surface rather than capture
                // (safe degrade, same posture as `OpenCaptureIntent`).
                HLLog.notifications.error(
                    "Quick-Action marker write failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
            return true
        }
    }
#endif
