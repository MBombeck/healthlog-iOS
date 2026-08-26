import Foundation

/// Static `id → points` lookup for every achievement defined in the server
/// library. Sourced **verbatim** from
/// `<server-repo>/src/lib/gamification/achievements.ts`
/// (the five tiered families expand via `buildStreakAchievements` with the
/// shape `<idPrefix>-<target>` and a `[1, 7, 30, 180, 360]` target list).
///
/// **Why this exists (A7 §1.3 user-report #9 — Achievements points missing):**
/// The server's `/api/gamification/achievements?format=ios` adapter still
/// strips the `points` field (server `route.ts:879-888`). Until that adapter
/// widens, iOS hydrates the value client-side keyed by the stable
/// `definition.id`. When the server emission widens, the lookup degrades
/// gracefully — `value(for:)` becomes the fallback for IDs the JSON happens
/// to omit.
///
/// **Source-tracking rule:** new achievement IDs added on the server **must**
/// be mirrored here, otherwise the cell + detail sheet render `0 Punkte`.
/// Compile-time guard isn't possible (server is a separate repo) so the
/// `AchievementPointsCoverageTests` suite asserts the iOS table covers
/// every name the server's ACHIEVEMENT_DEFINITIONS exports.
public enum AchievementPoints {
    /// Returns the canonical points reward for an achievement ID, or `nil`
    /// if unknown. Callers should treat `nil` as "render as 0 Punkte but
    /// surface a soft warning in logs" — never crash.
    public static func value(for id: String) -> Int? {
        table[id]
    }

    /// Snapshot of every server-known achievement id → points value.
    /// Listed in source order from `achievements.ts` to keep diff-review
    /// trivial when the server library grows.
    public static let table: [String: Int] = [
        // ─── Intake totals (5) ─────────────────────────────────
        "intake-total-1": 8,
        "intake-total-10": 24,
        "intake-total-50": 60,
        "intake-total-150": 140,
        "intake-total-300": 320,
        // ─── Compliance edge cases (2) ─────────────────────────
        "over-intake-1": 0,
        "skipped-intake-1": 0,
        // ─── Account / passkey / security (4) ──────────────────
        "passkey-created-1": 40,
        "passkey-login-1": 45,
        "password-login-1": 20,
        "bugreport-1": 30,
        // ─── Login streaks (2) ─────────────────────────────────
        "login-streak-7": 90,
        "login-streak-30": 280,
        // ─── On-time-perfect streak family (5) ─────────────────
        "on-time-perfect-1": 15,
        "on-time-perfect-7": 45,
        "on-time-perfect-30": 120,
        "on-time-perfect-180": 320,
        "on-time-perfect-360": 700,
        // ─── Compliance ≥80% streak family (5) ─────────────────
        "compliance-80-1": 25,
        "compliance-80-7": 85,
        "compliance-80-30": 240,
        "compliance-80-180": 650,
        "compliance-80-360": 1500,
        // ─── BMI green-zone streak family (5) ──────────────────
        "bmi-green-1": 18,
        "bmi-green-7": 55,
        "bmi-green-30": 145,
        "bmi-green-180": 380,
        "bmi-green-360": 850,
        // ─── BP green-zone streak family (5) ───────────────────
        "bp-green-1": 20,
        "bp-green-7": 60,
        "bp-green-30": 160,
        "bp-green-180": 420,
        "bp-green-360": 950,
        // ─── Pulse green-zone streak family (5) ────────────────
        "pulse-green-1": 14,
        "pulse-green-7": 40,
        "pulse-green-30": 105,
        "pulse-green-180": 280,
        "pulse-green-360": 620,
        // ─── Mood (4) ──────────────────────────────────────────
        "mood-first": 8,
        "mood-streak-7": 50,
        "mood-streak-30": 200,
        "mood-up-7": 90,
        // ─── Weight (3) ────────────────────────────────────────
        "weight-first": 8,
        "weight-50": 90,
        "weight-200": 320,
        // ─── BP (3) ────────────────────────────────────────────
        "bp-first": 8,
        "bp-50": 90,
        "bp-200": 320,
        // ─── Pulse (1) ─────────────────────────────────────────
        "pulse-first": 8,
        // ─── Engagement (3) ────────────────────────────────────
        "consistent-month": 140,
        "entry-streak-7": 90,
        "entry-streak-30": 260,
        "weekend-warrior": 40,
        // ─── Hidden (6) ────────────────────────────────────────
        "hidden-night-owl": 25,
        "hidden-early-bird": 25,
        "hidden-leap-day": 50,
        "hidden-doctor-pdf": 35,
        "hidden-locale-flip": 15,
        "hidden-bug-buddy": 60,
        // ─── Care achievements (6, server v1.16.1) ─────────────
        "miss-free-7": 60,
        "miss-free-30": 200,
        "miss-free-90": 520,
        "measurement-weeks-4": 120,
        "self-context-complete": 40,
        "sleep-log-7": 50
    ]

    /// Sorted list of known IDs — used by drift-coverage tests + previews.
    public static var knownIDs: [String] {
        table.keys.sorted()
    }
}
