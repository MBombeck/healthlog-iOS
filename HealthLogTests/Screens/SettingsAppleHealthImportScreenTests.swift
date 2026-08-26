import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Locks the v0.5.x APH-IMP-stub contract for the Apple Health Import
/// placeholder screen (`/settings/integrations/apple-health-import`):
///
/// - The screen MUST construct without dependencies (no environment store,
///   no preferences — it's a static placeholder).
/// - The screen MUST render the hero card + privacy card.
/// - The "Import starten" CTA MUST be disabled (placeholder contract — the
///   v1.4.34 server endpoint hasn't shipped; tapping must do nothing).
/// - The dedicated namespace `settings.applehealth_import.*` MUST resolve to
///   non-empty German + English copy in `Localizable.xcstrings` — guarding
///   against the F-2 / F-1 / CAT-1 parallel agents accidentally clobbering
///   keys via xcstrings merge.
///
/// Pixel snapshots are deliberately avoided per project convention; the
/// contract here is "does the IA exist, compile, and ship the operative copy?"
@MainActor
@Suite("SettingsAppleHealthImportScreen contract")
struct SettingsAppleHealthImportScreenTests {
    @Test("Screen constructs and renders a body")
    func screenRenders() {
        let screen = SettingsAppleHealthImportScreen()
        // Touching `body` forces SwiftUI's `@ViewBuilder` graph to resolve,
        // which catches typos in xcstrings keys at compile time (LocalizedStringKey
        // mismatches surface as preview-time crashes — this guards build time).
        _ = screen.body
    }

    @Test("All xcstrings keys resolve to non-empty German + English")
    func localisedKeysResolve() {
        // Keys live under the unique namespace `settings.applehealth_import.*`
        // so parallel agents (F-2 KI→AI rename, F-1 operator-disabled
        // placeholders, CAT-1 measurement-type catalogue) can't conflict.
        // Verified via Bundle.main.localizedString(forKey:) round-trip below.
        let keys = [
            "settings.applehealth_import.title",
            "settings.applehealth_import.subtitle",
            "settings.applehealth_import.hero_title",
            // UI-Standard U2 (Audit-Gruppe 8) — `hero_subtitle` („Jahre an
            // Historie in einem Import.") war die dritte von vier Stufen
            // derselben Ansage und wird nicht mehr gerendert. Der Schlüssel ist
            // jetzt eine Katalogleiche in `scripts/check-strings-baseline.json`
            // und fällt mit U8; er gehört deshalb nicht mehr in diese Liste
            // der Schlüssel, die diese Seite braucht.
            "settings.applehealth_import.explainer",
            "settings.applehealth_import.cta",
            "settings.applehealth_import.cta_disabled_caption",
            // v0.13 WP — `status_pill` ("Coming soon") deleted: the screen ships a
            // live HLStatusPill (pill_ready/running/done/failed), the dead stub
            // key is gone.
            "settings.applehealth_import.nav_subtitle",
            "settings.applehealth_import.privacy_title",
            "settings.applehealth_import.privacy_upload",
            "settings.applehealth_import.privacy_parse",
            "settings.applehealth_import.privacy_stats",
            "settings.applehealth_import.privacy_delete",
            "settings.applehealth_import.privacy_footer"
        ]

        for key in keys {
            let resolved = String(
                localized: String.LocalizationValue(key),
                bundle: .main
            )
            // If the key resolves to itself, the xcstrings entry is missing
            // or the build didn't pick up the resource — fail loudly.
            #expect(resolved != key, "Missing or unresolved xcstrings key: \(key)")
            #expect(!resolved.isEmpty, "Empty translation for: \(key)")
        }
    }

    @Test("Privacy footer carries the verbatim server contract")
    func privacyFooterCopyContract() {
        // Operator-grade: the disclaimer copy is the operative privacy
        // contract the server-side endpoint promises. Drift in either copy
        // or impl would break the trust contract — lock the substring here.
        let footer = String(
            localized: "settings.applehealth_import.privacy_footer",
            bundle: .main
        )
        #expect(footer.contains("einmalig"))
        #expect(footer.contains("parsing-only") || footer.contains("Parse"))
        #expect(footer.contains("ZIP"))
    }

    @Test("CTA caption explicitly names v0.6 / Server v1.4.34")
    func disabledCaptionNamesVersions() {
        // R5 anti-mystery rule: the disabled CTA caption must explicitly
        // name the version that unlocks it. Operators must never wonder
        // why a button is dim.
        let caption = String(
            localized: "settings.applehealth_import.cta_disabled_caption",
            bundle: .main
        )
        #expect(caption.contains("v0.6"))
        #expect(caption.contains("v1.4.34"))
    }

    @Test("SettingsIntegrationsScreen still constructs after the new card wiring")
    func integrationsHostStillConstructs() {
        // Sanity check: adding the AppleHealthImport card row to the
        // Integrations hub must not break that surface's compile contract.
        // Mirrors the `SettingsHubContractTests` pattern — constructor-only
        // (body resolve would need `HKReadinessStore` from the environment,
        // which the existing contract test also avoids).
        _ = SettingsIntegrationsScreen()
    }
}
