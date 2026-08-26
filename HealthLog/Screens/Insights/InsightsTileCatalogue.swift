import Foundation
import SwiftUI

/// v0.6.1.10 Y9-D2/D3 — single source of truth for the user-toggleable
/// Insights tile catalogue.
///
/// **What this owns:**
/// 1. The full catalogue of tile-IDs the operator can flip on/off in the
///    new `SettingsInsightsCustomizationScreen`. IDs match the server's
///    `TargetItem.type` enum so the same identifier flows end-to-end
///    from the API row through this preferences layer into the
///    `InsightsTargetTileGrid` render.
/// 2. The default-enabled set — the seven tiles Y3 shipped:
///    `WEIGHT`, `PULSE`, `RESTING_HR`, `MOOD_SCORE`, `MOOD_STABILITY`,
///    `ACTIVITY_STEPS`, `MEDICATION_COMPLIANCE`. Any new target the
///    server exposes (`SLEEP_DURATION`, `BODY_FAT`, …) is exposed to the
///    user in the customization screen but ships disabled by default
///    so the Y3 visual rhythm is preserved on upgrade.
/// 3. Persistence schema. The enabled-set lives in `UserDefaults` under
///    `hl.insights.enabledTiles` as a comma-joined string of tile-IDs.
///    Comma-joined (not JSON) keeps the value `@AppStorage`-readable
///    directly from any SwiftUI view; the helper here parses the
///    comma-list back into a `Set<String>` so callers never juggle the
///    raw wire format.
public enum InsightsTileCatalogue {
    /// `UserDefaults` / `@AppStorage` key the preferences live under.
    /// Never rename — operator preferences would silently reset.
    public static let enabledTilesStorageKey = "hl.insights.enabledTiles"

    /// **v0.6.1.12 Y9.2-B.** `UserDefaults` / `@AppStorage` key the
    /// user-defined tile ORDER lives under. Comma-joined list of tile-IDs
    /// (no sentinel needed — empty string falls back to `defaultEnabled`
    /// order so a fresh install renders the canonical Y3 sequence).
    /// Auto-hide-empty still trumps ordering; a hidden tile holds no
    /// slot regardless of position.
    public static let tileOrderStorageKey = "hl.insights.tileOrder"

    /// Y3-default enabled IDs — the seven tiles that shipped with the
    /// v0.6.1.1 Insights redesign. Used as the fallback when the
    /// persisted string is empty (fresh install) AND as the contract
    /// pin in `InsightsTileCatalogueTests`.
    public static let defaultEnabled: [String] = [
        "WEIGHT",
        "PULSE",
        "RESTING_HR",
        "MOOD_SCORE",
        "MOOD_STABILITY",
        "ACTIVITY_STEPS",
        "MEDICATION_COMPLIANCE"
    ]

    /// Decode the comma-joined `@AppStorage` value into a `Set<String>`.
    /// Empty string → default-enabled set so a fresh install renders the
    /// Y3-shipped tiles. Non-empty string → whatever the operator picked,
    /// even if that's an empty `Set` (operator explicitly turned every
    /// tile off).
    public static func decodeEnabled(_ raw: String) -> Set<String> {
        if raw.isEmpty {
            return Set(defaultEnabled)
        }
        // Operator-explicit empty set is encoded as a special sentinel
        // ("__none__") so we can distinguish "fresh install" (empty
        // string → default-enabled) from "operator turned every tile
        // off" (sentinel → empty set).
        if raw == emptyEncoded {
            return []
        }
        return Set(raw.split(separator: ",").map(String.init))
    }

    /// Encode the operator's enabled-set back into the wire format. The
    /// empty-set sentinel preserves operator intent across launches.
    public static func encodeEnabled(_ enabled: Set<String>) -> String {
        if enabled.isEmpty {
            return emptyEncoded
        }
        // Order doesn't matter for set semantics, but sorting keeps the
        // serialised value stable so a UserDefaults inspector / debug
        // dump reads the same on every launch.
        return enabled.sorted().joined(separator: ",")
    }

    /// Sentinel value encoding "operator turned every tile off". Distinct
    /// from the fresh-install empty string.
    private static let emptyEncoded = "__none__"

    /// **v0.6.1.12 Y9.2-B.** Decode the comma-joined `@AppStorage` tile-
    /// order value into an ordered array of tile-IDs. Empty string falls
    /// back to `defaultEnabled` so a fresh install renders the canonical
    /// Y3 sequence. Callers should reconcile the decoded order against
    /// the actual set of available IDs (drop unknowns, append late
    /// arrivals) — that reconciliation lives in
    /// `orderedEnabled(allCatalogueIDs:enabled:)` below so callers never
    /// rebuild it.
    public static func decodeOrder(_ raw: String) -> [String] {
        if raw.isEmpty {
            return defaultEnabled
        }
        return raw.split(separator: ",").map(String.init)
    }

    /// **v0.6.1.12 Y9.2-B.** Encode an ordered tile-ID list back into the
    /// wire format. Order matters here — no alphabetical sort, the
    /// operator's drag sequence is the authority.
    public static func encodeOrder(_ order: [String]) -> String {
        order.joined(separator: ",")
    }

    /// **v0.6.1.12 Y9.2-B.** The order in which to render tiles on the
    /// Insights surface. Honours the operator-defined order from
    /// `tileOrderStorageKey`, drops IDs that no longer exist in the
    /// catalogue, and appends late arrivals (server adds a new target
    /// the operator never reordered) in alphabetical order so the new
    /// row is at least deterministic. Enabled-set filtering happens at
    /// the call-site (the grid view), so disabled IDs flow through this
    /// list — they just don't render.
    public static func orderedCatalogue(
        rawOrder: String,
        allCatalogueIDs: Set<String>
    ) -> [String] {
        let stored = decodeOrder(rawOrder)
        var seen: Set<String> = []
        var out: [String] = []
        for id in stored where allCatalogueIDs.contains(id) {
            if seen.insert(id).inserted {
                out.append(id)
            }
        }
        let extras = allCatalogueIDs
            .subtracting(out)
            .sorted()
        out.append(contentsOf: extras)
        return out
    }
}
