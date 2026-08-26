import Foundation

/// Pure, platform-free decision for whether cycle tracking is **offered**.
///
/// Lives in `HealthLogCore` so it is unit-testable without HealthKit / SwiftUI
/// and so the same truth-table runs everywhere. The HealthKit `biologicalSex`
/// signal is injected as a plain ``BiologicalSexSignal`` value — the gate
/// itself NEVER touches HealthKit and NEVER triggers a permission prompt; the
/// app-side `CycleGate` is responsible for only reading an *already-granted*
/// biological-sex characteristic (never for men, never to decide visibility).
///
/// **Single source of truth** (`RESEARCH-cycle.md` §2). Resolution order:
/// 1. Explicit opt-in (Settings UI-pref) → always on. Covers trans /
///    non-binary women + the `OTHER` gender value + a skipped gender field.
/// 2. Server `UserProfile.gender` → ``genderEnablesCycle(_:)``, which names
///    **every** stored value explicitly (server-first, travels with the
///    account, no extra HK prompt for men).
/// 3. HealthKit `biologicalSex == .female` **fallback ONLY** when HK auth was
///    already granted independently. Never prompts; never for men.
/// Otherwise → off (the `.cycle` capture row is simply never built).
public enum CycleGateResolver {
    /// HealthKit biological-sex signal, mapped to a plain value so the
    /// resolver stays HK-free. Mirrors `HKBiologicalSex` cases.
    public enum BiologicalSexSignal: Sendable, Equatable {
        /// HK auth NOT granted (or never read) — the fallback MUST NOT be used.
        case unknown
        case notSet
        case female
        case male
        case other
    }

    /// Inputs to the gate. All plain values — no HK, no UI.
    public struct Input: Sendable, Equatable {
        /// `UserProfile.gender` (server) — `"MALE" | "FEMALE" | "OTHER" | nil`.
        /// Read case-insensitively (see ``genderEnablesCycle(_:)``); the
        /// canonical spelling has been uppercase since the server tightened
        /// `profileSchema` (verified 2026-07-30, CU-17 / GH #71).
        public var profileGender: String?
        /// Biological-sex characteristic. Pass `.unknown` unless HK auth was
        /// already granted independently (NEVER prompt to populate this).
        public var biologicalSex: BiologicalSexSignal
        /// Explicit Settings opt-in (UI-pref). True force-enables.
        public var explicitOptIn: Bool

        public init(
            profileGender: String?,
            biologicalSex: BiologicalSexSignal = .unknown,
            explicitOptIn: Bool = false
        ) {
            self.profileGender = profileGender
            self.biologicalSex = biologicalSex
            self.explicitOptIn = explicitOptIn
        }
    }

    /// Does the stored profile gender **on its own** turn the module on?
    ///
    /// Every value the server can store is named here, so the third value is a
    /// *decision* and not a fall-through — that fall-through is exactly the bug
    /// class GH #71 found nine times on the server side (a person with `OTHER`
    /// or no recorded gender silently landing in the male branch). Comparison
    /// is case-insensitive: canonical is uppercase, older rows may be lowercase.
    ///
    /// - `FEMALE` → on.
    /// - `MALE` → off **from this signal**. Never gender-derived for men.
    /// - `OTHER` → deliberately **not decided by gender**. The value carries no
    ///   information about whether this person menstruates, so guessing in
    ///   either direction would be wrong. These users reach the module through
    ///   the explicit opt-in (step 1 of ``isAvailable(_:)``) — the documented
    ///   route for everyone whose cycle module does not follow from a profile
    ///   gender — or through an already-granted HealthKit characteristic
    ///   (step 3). Neither path is closed by returning `false` here.
    /// - absent / unrecognised → off from this signal, same reasoning as
    ///   `OTHER`: absence is not evidence, and it is never read as "male".
    public static func genderEnablesCycle(_ profileGender: String?) -> Bool {
        switch profileGender?.lowercased() {
        case "female": true
        case "male": false
        case "other": false
        default: false
        }
    }

    /// Resolve whether cycle tracking should be offered.
    public static func isAvailable(_ input: Input) -> Bool {
        // 1. Explicit opt-in wins (covers trans / non-binary / `OTHER`).
        if input.explicitOptIn { return true }

        // 2. Server-first: every stored gender value is decided explicitly.
        if genderEnablesCycle(input.profileGender) { return true }

        // 3. HK fallback — ONLY when a real granted characteristic says female.
        //    `.unknown` (no grant) must NOT enable; `.male` must NEVER enable.
        if input.biologicalSex == .female { return true }

        return false
    }
}
