import Foundation

/// **App Group coordinates shared by the app + the
/// `dev.healthlog.app.widgets` extension.**
///
/// The Home / Lock-Screen widgets paint from a tiny snapshot the app
/// writes into the shared App Group container — no network round-trip in
/// the widget process. This enum holds the single source of truth for the
/// group identifier + the snapshot filename so the writer (app) and the
/// reader (extension) can never drift apart. Compiled into **both**
/// targets via source membership (see `project.yml` `HealthLogWidgets`
/// sources allowlist).
///
/// **Storage choice — a file, not `UserDefaults(suiteName:)`.** The
/// snapshot is a small JSON blob read once per timeline build; a file in
/// the group container keeps it off the shared defaults plist (which the
/// app also uses for UI-prefs) and makes the read/write atomic + easy to
/// reason about. The container is the agreed shared surface registered in
/// the Apple Developer Portal as `group.dev.healthlog.app`.
public enum WidgetAppGroup {
    /// The shared App Group identifier. Mirrors the
    /// `com.apple.security.application-groups` entitlement on both the app
    /// and the widget extension.
    public static let identifier = "group.dev.healthlog.app"

    /// Filename of the widget snapshot inside the group container.
    public static let snapshotFilename = "widget-snapshot.json"

    /// Filename of the one-shot "open capture" marker
    /// the `OpenCaptureIntent` (Control Center / Action-Button "Erfassen"
    /// control) drops and the app consumes on foreground. See
    /// ``CaptureRequestStore``.
    public static let captureRequestFilename = "capture-request.json"

    /// Filename of the next-dose widget's
    /// two-step "Genommen" pending-confirm marker. The widget intent's first
    /// tap arms it, the second tap (or a stale-window expiry) clears it. See
    /// ``WidgetPendingConfirmStore``.
    public static let pendingConfirmFilename = "widget-pending-confirm.json"

    /// Filename of the last "Taken" outcome a widget or control intent saw.
    /// See ``WidgetDoseOutcomeStore``.
    public static let doseOutcomeFilename = "widget-dose-outcome.json"
    /// #188 (7) — doses taken outside the app, offered for undo on next open.
    public static let externalTakeLogFilename = "external-take-log.json"

    /// Resolved URL of the snapshot file inside the shared container, or
    /// `nil` when the container is unavailable (e.g. the group is not
    /// provisioned in a given build configuration — unit tests, macOS).
    public static func snapshotURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    /// Resolved URL of the capture-request marker inside the shared
    /// container, or `nil` when the container is unavailable. Mirrors
    /// ``snapshotURL(fileManager:)``.
    public static func captureRequestURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(captureRequestFilename, isDirectory: false)
    }

    /// Resolved URL of the next-dose widget's pending-confirm marker inside
    /// the shared container, or `nil` when the container is unavailable.
    /// Mirrors ``snapshotURL(fileManager:)``.
    public static func pendingConfirmURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(pendingConfirmFilename, isDirectory: false)
    }

    /// Resolved URL of the dose-outcome marker inside the shared container,
    /// or `nil` when the container is unavailable.
    /// Resolved URL of the external-take log inside the shared container.
    public static func externalTakeLogURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(externalTakeLogFilename, isDirectory: false)
    }

    public static func doseOutcomeURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(doseOutcomeFilename, isDirectory: false)
    }
}
