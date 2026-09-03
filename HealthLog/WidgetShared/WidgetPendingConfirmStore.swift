import Foundation

/// **v0.10.0 W-Widget-2Tap — the Home-screen next-dose widget's two-step
/// "Genommen" confirm state, shared between the widget extension and itself
/// across timeline reloads via the App Group container.**
///
/// The Live Activity solves the same anti-accidental problem by reading the
/// running `Activity`'s `ContentState` (armed vs. confirmed) inside its
/// intent. A Home-screen widget has **no** Activity to hold that transient
/// state — so the equivalent "armed?" flag lives in a tiny App Group blob
/// that the firing intent writes and the `TimelineProvider` reads back when
/// it rebuilds the entry. This mirrors the LA's two-step exactly:
///
/// - FIRST tap → ``arm(medicationId:scheduledFor:)`` writes the pending
///   marker (no intake recorded), then the intent reloads the timeline so
///   the button re-renders as "Erneut tippen zum Bestätigen".
/// - SECOND tap (marker present + fresh) → the intent records the intake and
///   ``clear()``s the marker.
/// - A stale marker (older than ``pendingConfirmWindow``) auto-reverts: both
///   ``armed(for:now:)`` and the timeline read treat it as absent, so the
///   button falls back to the plain "Genommen" on the next render.
///
/// **Storage choice — a file, not `UserDefaults(suiteName:)`.** Matches the
/// established ``WidgetSnapshotStore`` / ``CaptureRequestStore`` convention:
/// a single tiny atomic JSON blob in the group container, off the shared
/// defaults plist, trivially inspectable. **No PII** — the marker carries
/// only the medication id, the slot instant, and the arm timestamp.
public struct WidgetPendingConfirmStore: Sendable {
    private let url: URL?

    /// - Parameter url: override for tests; defaults to the resolved App
    ///   Group container file. `nil` (container unavailable) makes every
    ///   operation a safe no-op / `nil` read.
    public init(url: URL? = WidgetAppGroup.pendingConfirmURL()) {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? SensitiveDataBackupExclusion.secureCreatedItem(at: url)
        }
        self.url = url
    }

    /// How long the armed ("Bestätigen?") state stays actionable before it
    /// auto-reverts to the plain "Genommen" button. Matches the Live
    /// Activity's `MarkDoseFromLiveActivityIntent.pendingConfirmWindow`
    /// (4 s) so the two surfaces feel identical: long enough for a
    /// deliberate second tap, short enough that a stale armed button never
    /// lingers on the Home Screen.
    public static let pendingConfirmWindow: TimeInterval = 4

    /// The armed-confirm marker. Carries which medication is armed, the
    /// canonical slot instant the eventual intake records against, and when
    /// the arm happened (so a stale marker can be ignored).
    public struct Pending: Codable, Sendable, Equatable {
        public let medicationId: String
        public let scheduledAt: Date
        public let armedAt: Date

        public init(medicationId: String, scheduledAt: Date, armedAt: Date) {
            self.medicationId = medicationId
            self.scheduledAt = scheduledAt
            self.armedAt = armedAt
        }
    }

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

    /// FIRST tap — arm the pending-confirm marker for `medicationId` against
    /// its canonical slot instant. Overwrites any prior marker so arming a
    /// different dose re-starts the window cleanly. Throws on encode / write
    /// failure so the caller can log + carry on.
    public func arm(medicationId: String, scheduledFor: Date, now: Date = .now) throws {
        guard let url else { return }
        let pending = Pending(medicationId: medicationId, scheduledAt: scheduledFor, armedAt: now)
        let data = try Self.makeEncoder().encode(pending)
        // v0.12 W1 (security finding W1-2) — explicit protection class on the
        // App Group pending-confirm marker (carries a medication id + slot
        // instant = health data). `.completeFileProtectionUntilFirstUserAuthentication`
        // (NOT `.completeFileProtection`) so the widget extension can read the
        // marker to render the confirm-state button after first unlock while
        // locked; bytes stay encrypted at rest before first unlock.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try SensitiveDataBackupExclusion.secureCreatedItem(at: url)
    }

    /// Read the current marker **without** clearing it. Returns `nil` when
    /// no marker exists, the container is unavailable, the marker is corrupt,
    /// or it is older than ``pendingConfirmWindow`` (stale → treated as
    /// absent so the button auto-reverts). Never throws — a widget read must
    /// degrade to the plain button, not crash the timeline build.
    public func read(now: Date = .now) -> Pending? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let pending = try? Self.makeDecoder().decode(Pending.self, from: data) else {
            return nil
        }
        guard now.timeIntervalSince(pending.armedAt) <= Self.pendingConfirmWindow else {
            return nil
        }
        return pending
    }

    /// `true` when `medicationId` is currently armed for confirm (a fresh
    /// marker exists for exactly that medication). Drives whether the
    /// widget button renders "Bestätigen?" vs. "Genommen".
    public func armed(for medicationId: String, now: Date = .now) -> Bool {
        read(now: now)?.medicationId == medicationId
    }

    /// Build 273 (sync audit A17) — slot-bound arm check. The widget's
    /// next-dose slot can roll over inside the confirm window; a second tap
    /// that arrives for a DIFFERENT slot of the same medication must not
    /// commit the intake the first tap armed.
    public func armed(for medicationId: String, scheduledFor: Date, now: Date = .now) -> Bool {
        guard let pending = read(now: now) else { return false }
        return pending.medicationId == medicationId
            && abs(pending.scheduledAt.timeIntervalSince(scheduledFor)) < 1
    }

    /// Remove the marker (SECOND-tap commit, or an explicit reset). Best
    /// effort — a missing file is success. Never throws.
    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
