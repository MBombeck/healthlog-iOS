import Foundation

/// **v0.8.4 WWIDGET-3 — one-shot "open the capture flow" hand-off between the
/// Control Center / Action-Button "Erfassen" control and the app.**
///
/// The `OpenCaptureIntent` runs with `openAppWhenRun = true`, so its
/// `perform()` executes in the app process as the app comes to the
/// foreground. Rather than thread the `AppRouter` into the App-Intents
/// dependency graph (the existing intents deliberately avoid standing up the
/// composition root — see `IntentDependencies`), the intent drops a tiny
/// one-shot marker file into the shared App Group container; the app consumes
/// it on the next foreground / launch tick and flips to the capture surface.
///
/// **Why a file, not `UserDefaults(suiteName:)`:** matches the
/// `WidgetSnapshotStore` convention — a single tiny blob in the group
/// container, atomic, off the shared defaults plist, trivially inspectable.
/// **No PII** — the marker carries only a timestamp.
public struct CaptureRequestStore: Sendable {
    private let url: URL?

    /// - Parameter url: override for tests; defaults to the resolved App
    ///   Group container file. `nil` (container unavailable) makes every
    ///   operation a safe no-op.
    public init(url: URL? = WidgetAppGroup.captureRequestURL()) {
        self.url = url
    }

    /// Which in-app surface a consumed marker should route to. The marker
    /// hand-off is generic — `OpenCaptureIntent` requests the full capture
    /// picker, `LogMoodControl`'s intent (v0.10.0 W-Mood-B) requests the mood
    /// quick-entry sheet, and the Home-Screen Quick Actions (v0.14.x Q) request
    /// one of the three capture surfaces directly (measurement → picker,
    /// medication → quick-intake sheet, mood → quick-entry sheet). Defaults to
    /// `.capture` on decode so a marker written by an older build (no `surface`
    /// key) still routes to capture.
    public enum Surface: String, Codable, Sendable {
        case capture
        case mood
        /// v0.14.x Q — Home-Screen Quick Action "Log an intake": surfaces the
        /// medication quick-intake confirm sheet (same surface the central
        /// CapturePicker's `.medication` row hands off to).
        case medication
    }

    /// The one-shot marker payload. Carries the request timestamp (so a stale
    /// marker written-but-never-consumed can be ignored after a grace window)
    /// plus the target ``Surface``.
    public struct Request: Codable, Sendable, Equatable {
        public let requestedAt: Date
        public let surface: Surface

        public init(requestedAt: Date, surface: Surface = .capture) {
            self.requestedAt = requestedAt
            self.surface = surface
        }

        /// Decode with a `.capture` fallback for the legacy (surface-less)
        /// marker shape so a control tap from an older app build still routes.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestedAt = try c.decode(Date.self, forKey: .requestedAt)
            surface = try c.decodeIfPresent(Surface.self, forKey: .surface) ?? .capture
        }

        private enum CodingKeys: String, CodingKey {
            case requestedAt
            case surface
        }
    }

    /// How long a written-but-unconsumed marker stays actionable. A control
    /// tap that opens the app fires within seconds; a marker older than this
    /// is treated as abandoned and dropped without surfacing capture.
    public static let staleAfter: TimeInterval = 60

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Write the one-shot capture marker. Throws on encode / write failure so
    /// the intent can decide whether to log + carry on.
    public func write(_ request: Request = Request(requestedAt: .now)) throws {
        guard let url else { return }
        let data = try Self.makeEncoder().encode(request)
        // v0.12 W1 (security finding W1-2) — explicit protection class on the
        // App Group capture marker. `.completeFileProtectionUntilFirstUserAuthentication`
        // (NOT `.completeFileProtection`) so the widget/control extension can
        // still read+consume the marker after the first unlock while the device
        // is locked; bytes stay encrypted at rest before first unlock.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Read **and clear** the marker, returning a fresh (non-stale) request if
    /// one is pending. One-shot: the file is removed on read so a single
    /// control tap surfaces capture exactly once. Returns `nil` when no
    /// marker exists, the container is unavailable, or the marker is older
    /// than ``staleAfter``. Never throws — a failed consume must not break
    /// app foreground.
    public func consume(now: Date = .now) -> Request? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        // Remove first so even a decode failure clears a corrupt marker.
        try? FileManager.default.removeItem(at: url)
        guard let request = try? Self.makeDecoder().decode(Request.self, from: data) else {
            return nil
        }
        guard now.timeIntervalSince(request.requestedAt) <= Self.staleAfter else {
            return nil
        }
        return request
    }
}
