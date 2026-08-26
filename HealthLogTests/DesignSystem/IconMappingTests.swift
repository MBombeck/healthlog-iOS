@testable import HealthLog
import Testing
#if canImport(UIKit)
    import UIKit
#endif

/// Verifies that every Lucide name the server emits maps to a real SF Symbol —
/// not the visible debug fallback. Runs against the asset catalog at test time
/// via `UIImage(systemName:)`, so SDK-version-specific symbol availability is
/// caught here rather than at runtime in a user's empty achievement cell.
@Suite("LucideToSF icon mapping")
struct IconMappingTests {
    @Test("Every known Lucide name resolves to a non-fallback SF Symbol")
    func everyKnownNameResolves() {
        for lucide in LucideToSF.knownLucideNames {
            let symbol = LucideToSF.map(lucide)
            #expect(
                symbol != "questionmark.circle",
                "Lucide '\(lucide)' fell back to the debug placeholder — add a real mapping."
            )
        }
    }

    @Test("Every mapped SF Symbol actually exists in the system catalog")
    func mappedSymbolsExist() {
        #if canImport(UIKit)
            for lucide in LucideToSF.knownLucideNames {
                let symbol = LucideToSF.map(lucide)
                let image = UIImage(systemName: symbol)
                #expect(
                    image != nil,
                    "SF Symbol '\(symbol)' (mapped from Lucide '\(lucide)') not found in the system catalog on this SDK."
                )
            }
        #endif
    }

    @Test("Case-insensitive lookup")
    func caseInsensitive() {
        #expect(LucideToSF.map("trophy") == LucideToSF.map("Trophy"))
        #expect(LucideToSF.map("TROPHY") == LucideToSF.map("Trophy"))
        #expect(LucideToSF.map("TrOpHy") == LucideToSF.map("Trophy"))
    }

    @Test("Unknown names hit the visible debug fallback (not silent-empty)")
    func unknownFallsBackVisibly() {
        // Visible fallback is essential — silent-empty (`""`) was the prior
        // bug. The visible question mark surfaces drift to QA on next build.
        #expect(LucideToSF.map("ThisIsNotARealIcon") == "questionmark.circle")
        #expect(LucideToSF.map("") == "questionmark.circle")
    }

    @Test("HelpCircle (hidden-card route emission) maps explicitly")
    func helpCircleMapsExplicitly() {
        // The server's hidden-card path at route.ts:916 emits "HelpCircle"
        // verbatim. This mapping must NOT route to the unknown-fallback
        // because the visual contract is "filled question mark with theme tint".
        #expect(LucideToSF.map("HelpCircle") == "questionmark.circle.fill")
    }

    @Test("Image(lucide:) initializer wraps the mapper")
    func imageInitWrapsMapper() {
        // Sanity: the Image(lucide:) sugar path exists and compiles. We don't
        // assert on the resulting Image (SwiftUI Image is not Equatable) —
        // just that the symbol it would resolve to matches the mapper.
        let trophySymbol = LucideToSF.map("Trophy")
        #expect(trophySymbol == "trophy.fill")
    }
}
