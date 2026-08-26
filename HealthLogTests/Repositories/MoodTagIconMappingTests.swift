import Foundation
import Testing

#if !SWIFT_PACKAGE

    @testable import HealthLog

    /// #21 — the Lucide→SF-Symbol map (`MoodTagSFSymbol`) must cover the full
    /// server icon catalog (`src/lib/mood/icon-catalog.ts`, 74 names) and a
    /// blank icon must never be possible: an unknown / future name resolves to
    /// the neutral `tag` glyph instead of rendering nothing.
    @MainActor
    @Suite("Mood-tag icon mapping (#21)")
    struct MoodTagIconMappingTests {
        /// The server's canonical Lucide catalog, verbatim from issue #21
        /// (`MOOD_TAG_ICON_CATALOG`, append-only, 74 names). Every one of these
        /// must resolve to a non-empty SF Symbol so a web-created tag using any
        /// of them never renders blank on iOS.
        static let serverCatalog: [String] = [
            "Activity", "AlertTriangle", "Angry", "Apple", "Baby", "Banknote",
            "Bath", "Bed", "BedDouble", "Bike", "Book", "BookOpen", "Brain",
            "Briefcase", "Camera", "CandyOff", "Car", "Cat", "CheckCircle",
            "Cigarette", "CigaretteOff", "Clock", "Cloud", "CloudMoon",
            "CloudRain", "CloudSun", "Coffee", "Dog", "Dumbbell", "Film",
            "Flame", "Footprints", "Frown", "Gift", "GlassWater",
            "GraduationCap", "HandHeart", "Headphones", "Heart", "HeartPulse",
            "HelpCircle", "Home", "House", "Laugh", "Leaf", "LogOut", "Meh",
            "Moon", "MoonStar", "Mountain", "Music", "Palette", "PartyPopper",
            "Phone", "Pill", "Pizza", "Plane", "ShoppingCart",
            "SlidersHorizontal", "Smile", "Star", "Stethoscope", "Sun", "Swords",
            "Syringe", "Tag", "Thermometer", "ThumbsUp", "Trees", "User",
            "Users", "UtensilsCrossed", "Wine", "Zap"
        ]

        @Test("Every server-catalog Lucide name resolves to a non-empty SF Symbol")
        func everyServerCatalogNameResolves() {
            #expect(Self.serverCatalog.count == 74)
            for name in Self.serverCatalog {
                let symbol = MoodTagSFSymbol.symbol(forLucide: name)
                // Must have an explicit table entry (not rely on the fallback).
                #expect(symbol != nil, "\(name) is missing from the symbol table")
                #expect(symbol?.isEmpty == false, "\(name) resolved to an empty symbol")
                // Never echo the Lucide PascalCase name back as a "symbol".
                #expect(symbol != name, "\(name) must map to an SF Symbol, not echo the Lucide name")
                // The always-resolving allow-list resolver agrees and never blanks.
                #expect(MoodTagSFSymbol.symbolForAllowListIcon(name).isEmpty == false)
            }
        }

        @Test("The #21 regression names map to REAL SF Symbols, not the blank face glyphs")
        func regressionNamesMapToRealSymbols() {
            // `face.frowning` / `face.angry` are NOT real SF Symbols (only
            // face.smiling / face.dashed / face.smiling.inverse exist) — they
            // rendered blank. They must now map to existing glyphs.
            #expect(MoodTagSFSymbol.symbol(forLucide: "Frown") == "hand.thumbsdown")
            #expect(MoodTagSFSymbol.symbol(forLucide: "Angry") == "cloud.bolt")
            // And the still-valid neighbours stay put.
            #expect(MoodTagSFSymbol.symbol(forLucide: "Smile") == "face.smiling")
            #expect(MoodTagSFSymbol.symbol(forLucide: "Meh") == "face.dashed")
            #expect(MoodTagSFSymbol.symbol(forLucide: "Laugh") == "face.smiling.inverse")
        }

        @Test("The custom-icon allow-list is exactly the 74-name server catalog")
        func allowListEqualsServerCatalog() {
            #expect(Set(MoodTagCatalog.customIconAllowList) == Set(Self.serverCatalog))
            #expect(MoodTagCatalog.customIconAllowList.count == Self.serverCatalog.count)
        }

        @Test("An unknown icon name never renders blank (resolves to the neutral tag glyph)")
        func unknownIconFallsBackToTag() {
            // The blank path: a future / unrecognised server icon name still
            // resolves to a non-empty SF Symbol via the allow-list resolver.
            #expect(MoodTagSFSymbol.symbol(forLucide: "ThisIconDoesNotExist") == nil)
            #expect(MoodTagSFSymbol.symbolForAllowListIcon("ThisIconDoesNotExist") == "tag")
            #expect(MoodTagSFSymbol.symbol(forLucide: nil) == nil)
            #expect(MoodTagSFSymbol.symbol(forLucide: "") == nil)

            // A custom tag carrying an unmapped icon still draws a real glyph.
            let oddball = MoodTagDTO(
                key: "custom:abc",
                labelKey: "",
                icon: "SomeBrandNewLucideName",
                custom: true,
                label: "Gartenarbeit"
            )
            #expect(oddball.sfSymbol == "tag")
            #expect(MoodTagSFSymbol.symbol(forTag: oddball) == "tag")
        }

        @Test("Representative newly-mapped catalog icons resolve to sensible SF Symbols")
        func newCatalogIconsResolve() {
            let expected: [String: String] = [
                "Gift": "gift",
                "Bike": "bicycle",
                "Headphones": "headphones",
                "GraduationCap": "graduationcap",
                "Camera": "camera",
                "Mountain": "mountain.2",
                "ShoppingCart": "cart",
                "Phone": "phone",
                "Stethoscope": "stethoscope",
                "Syringe": "syringe",
                "Baby": "figure.child",
                "Leaf": "leaf",
                "Cat": "cat",
                "Dog": "dog",
                "Home": "house"
            ]
            for (lucide, sfSymbol) in expected {
                #expect(MoodTagSFSymbol.symbol(forLucide: lucide) == sfSymbol, "\(lucide) should map to \(sfSymbol)")
            }
        }
    }

#endif
