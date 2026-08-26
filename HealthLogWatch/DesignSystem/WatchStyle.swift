import SwiftUI

/// **v0.12 P2 — watch-local style helpers.**
///
/// Colours come from the shared, asset-catalog-free `LAColor` palette
/// (Tonal-Mono, status colours as signal-only) — the same palette the Live
/// Activity uses, so the watch matches the app's documented design system.
/// Spacing / radius / type use the canonical `HLSpace` / `HLRadius` /
/// `Font.hl*` tokens compiled in from `Tokens.swift`.
enum WatchStyle {
    /// Soft card background for grouped rows (monochrome surface).
    static var cardFill: some ShapeStyle {
        LAColor.surface.opacity(0.001)
    }
}

/// The five mood levels the quick-log offers, best-first (matches the app's
/// `ServerMoodLevel` 1…5). Titles are English source strings resolved to DE
/// via the watch String Catalog.
struct WatchMoodLevel: Identifiable {
    let score: Int
    let title: LocalizedStringKey

    var id: Int {
        score
    }

    /// Computed (not a stored static) so the non-Sendable `LocalizedStringKey`
    /// title doesn't make a static `let` concurrency-unsafe under Swift 6.
    static var all: [WatchMoodLevel] {
        [
            WatchMoodLevel(score: 5, title: "Great"),
            WatchMoodLevel(score: 4, title: "Good"),
            WatchMoodLevel(score: 3, title: "Okay"),
            WatchMoodLevel(score: 2, title: "Bad"),
            WatchMoodLevel(score: 1, title: "Lousy")
        ]
    }

    static func title(for score: Int) -> LocalizedStringKey {
        all.first { $0.score == score }?.title ?? "Okay"
    }

    /// Canonical score → mood-icon asset name. Mirrors the phone's
    /// `MoodCopy.iconName(for:)` (PNG pack `Mood1…Mood5`) so the wrist renders
    /// the SAME glyphs as the phone — no Unicode emoji. The `Mood1…Mood5`
    /// imagesets are copied into the watch asset catalog so `Image(_:)`
    /// resolves on watchOS. Out-of-range clamps to the scale endpoints.
    static func iconName(for score: Int) -> String {
        "Mood\(max(1, min(5, score)))"
    }
}
