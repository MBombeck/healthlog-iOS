import SwiftUI

/// Maps server-emitted Lucide React icon names (used in the achievements +
/// notification payloads) to their nearest SF Symbol equivalents.
///
/// **Why this exists (A7 §1.3 / user-report #9 — Achievements icons missing):**
/// The server's `/api/gamification/achievements?format=ios` adapter returns
/// `iconName` strings copied verbatim from the web's Lucide imports
/// (`"Trophy"`, `"Flame"`, `"Pill"` …). iOS feeds those into
/// `Image(systemName:)` which silently renders an empty placeholder when the
/// name is not a valid SF Symbol — exactly the "leere Kreise" user report.
///
/// The full server icon library (sourced from
/// `<server-repo>/src/lib/gamification/achievements.ts` —
/// every `icon: "..."` entry — plus the `HelpCircle` placeholder emitted by
/// the route's hidden-card path at `route.ts:916`) is mapped here. New entries
/// added on the server **must** be mirrored here, otherwise users see the
/// `questionmark.circle.fill` debug fallback.
///
/// The fallback is intentionally visible (not invisible) so QA spots drift on
/// the next build. Better a question mark than silently empty cells.
public enum LucideToSF {
    /// Lookup table, keyed by lowercased Lucide name. A flat dictionary (not a
    /// `switch`) keeps the mapping O(1) and lint-simple — the table only ever
    /// grows by literal rows when the server adds achievement icons.
    private static let sfSymbolByLucideName: [String: String] = [
        // --- Achievement library (achievements.ts) ---
        "activity": "waveform.path.ecg",
        "alerttriangle": "exclamationmark.triangle.fill",
        "bug": "ladybug.fill",
        "calendarcheck": "calendar.badge.checkmark",
        "calendardays": "calendar",
        // v1.16.1 care achievements (miss-free / measurement-weeks /
        // self-context-complete / sleep-log)
        "calendarrange": "calendar.badge.clock",
        "clipboardcheck": "checklist.checked",
        "filetext": "doc.text.fill",
        "fingerprint": "touchid",
        "flame": "flame.fill",
        "heart": "heart.fill",
        "keyround": "key.fill",
        "languages": "character.bubble.fill",
        "login": "arrow.right.circle.fill",
        "moon": "moon.fill",
        "moonstar": "moon.stars.fill",
        "pill": "pill.fill",
        "scale": "scalemass.fill",
        "shieldcheck": "checkmark.shield.fill",
        "skipforward": "forward.fill",
        "smile": "face.smiling.fill",
        "sparkles": "sparkles",
        "sun": "sun.max.fill",
        "target": "target",
        "trophy": "trophy.fill",
        "usercheck": "person.crop.circle.badge.checkmark",
        // --- Special-case route emissions ---
        "helpcircle": "questionmark.circle.fill"
    ]

    /// Returns the SF Symbol name for a Lucide icon. Case-insensitive.
    /// Falls back to `questionmark.circle` for unknown names — the
    /// defensive, intentionally visible debug-flag for drift.
    public static func map(_ lucideName: String) -> String {
        sfSymbolByLucideName[lucideName.lowercased()] ?? "questionmark.circle"
    }

    /// Every Lucide name this mapping table acknowledges as known.
    /// Source of truth for tests + drift assertions. Order matches the
    /// server's `achievements.ts` definitions plus the hidden-card path.
    public static let knownLucideNames: [String] = [
        "Activity", "AlertTriangle", "Bug", "CalendarCheck", "CalendarDays",
        "CalendarRange", "ClipboardCheck",
        "FileText", "Fingerprint", "Flame", "Heart", "KeyRound",
        "Languages", "LogIn", "Moon", "MoonStar", "Pill", "Scale",
        "ShieldCheck", "SkipForward", "Smile", "Sparkles", "Sun",
        "Target", "Trophy", "UserCheck",
        "HelpCircle"
    ]
}

/// SwiftUI sugar: `Image(lucide: "Trophy")` is the canonical call-site for
/// rendering a server-emitted icon. Use this instead of `Image(systemName:)`
/// everywhere you accept a server-shaped icon string.
public extension Image {
    init(lucide name: String) {
        self.init(systemName: LucideToSF.map(name))
    }
}

#Preview("LucideToSF — Achievement library") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: HLSpace.lg) {
            ForEach(LucideToSF.knownLucideNames, id: \.self) { name in
                VStack(spacing: HLSpace.xs) {
                    // Intentional fixed size:
                    // Preview-only grid; icon locked to fixed 56×56 chip.
                    Image(lucide: name)
                        // swiftlint:disable:next dynamic_type_bypass
                        .font(.system(size: 28))
                        .foregroundStyle(HLText.primary)
                        .frame(width: 56, height: 56)
                        .background(HLSurface.tertiary)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.tile))
                    Text(name)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
        .padding()
    }
    .hlScreenBackground()
}
