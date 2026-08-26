import Foundation

/// **audit-v0162 M-7 — "does the configured server materialise today's dose
/// slots itself?", cached across launches.**
///
/// `MedicationsStore.derivedIntakeSynthesisEnabledProvider` is **synchronous**
/// (it is read inside the `derivedTodayIntakes` computed property, on every
/// render) while the only honest answer — `GET /api/version` — is
/// **asynchronous**. There is therefore a window between launch and the first
/// probe answering, and offline there is no answer at all. This box holds the
/// last-known verdict and persists it so that window exists **once per
/// installation** instead of once per cold start.
///
/// ## The default while the verdict is unknown
///
/// `synthesisEnabled` is `false` until a probe has answered — i.e. **do not
/// synthesise**. Both directions cost something:
///
/// - *Synthesise while unknown* → on a modern (slot-materialising) server the
///   client mints a placeholder next to the server's own row whenever the two
///   `scheduledFor` instants differ by more than the ±5-min dedup window (a
///   schedule-era edit, a DST seam, a device-TZ ≠ profile-TZ seam). That is an
///   inflated "N offen", a phantom overdue dose in the compliance ring that
///   nobody can take, and an inflated app badge — i.e. an invitation to take a
///   dose twice, the one hazard PROJECT_GUIDE.md draws a hard line around.
/// - *Do not synthesise while unknown* → on a server older than
///   ``MedicationSlotMaterialization/minimumServerVersion`` a dose the server
///   has not minted yet is missing from the due surfaces until the probe lands.
///
/// The second is both rarer and milder. The threshold is v1.8.1 (2026-06-01)
/// and the live server is v1.35.1, so a server below the threshold is a
/// museum piece; a pre-1.8.1 server also still materialises the *first* slot of
/// every schedule, so the miss is partial and the ad-hoc "Erfassen" path stays
/// open. The phantom, by contrast, is the double-dose shape the server itself
/// just fixed on its side in v1.35.1. When in doubt we trust the ledger and
/// show nothing rather than invent a dose.
///
/// ## Why UserDefaults
///
/// The verdict is a capability fact about a host — not PHI, not a token, not a
/// health value — so it belongs in the UI-pref tier PROJECT_GUIDE.md permits.
/// `PrivacyInfo.xcprivacy` already declares `UserDefaults` under CA92.1; this
/// key needs no new reason code. It is deliberately **not** `LogoutClearable`:
/// signing out does not change what the server can do, and forgetting the
/// verdict on every token expiry would re-open the unknown window for no gain.
/// `AppContainer.reloadEnvironment()` calls ``forget()`` instead — that is the
/// one event (the operator re-pointed the app at another host) after which the
/// cached answer is genuinely about the wrong server.
@MainActor
public final class MedicationSlotMaterializationGate {
    /// UserDefaults key holding the last-known verdict. Absent = never probed.
    static let defaultsKey = "hl.medications.serverMaterializesSlots"

    private let defaults: UserDefaults

    /// Last-known answer for the configured server, or `nil` while no probe has
    /// ever answered on this installation.
    public private(set) var serverMaterializesSlots: Bool?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverMaterializesSlots = defaults.object(forKey: Self.defaultsKey) as? Bool
    }

    /// Feeds `MedicationsStore.derivedIntakeSynthesisEnabledProvider`. Client
    /// synthesis is the fallback for a server that does **not** materialise
    /// slots — so it runs only on a verdict that positively says so.
    public var synthesisEnabled: Bool {
        serverMaterializesSlots == false
    }

    /// Record the verdict implied by a probed `/api/version` payload.
    public func apply(_ info: ServerVersionInfo) {
        record(MedicationSlotMaterialization.isAvailable(on: info))
    }

    /// Record (and persist) a verdict directly.
    public func record(_ materializes: Bool) {
        serverMaterializesSlots = materializes
        defaults.set(materializes, forKey: Self.defaultsKey)
    }

    /// Drop the cached verdict — the app was re-pointed at a different server,
    /// so the previous host's answer says nothing about this one.
    public func forget() {
        serverMaterializesSlots = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
