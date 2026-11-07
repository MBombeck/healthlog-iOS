// App-target symbols (`TodayHeroActionRoute`, `TodayHeroCopy`) are not in the
// SPM library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Every `daily.action.*` label the server (v1.47.1, `src/lib/daily/digest.ts`)
    /// sends resolves in the iOS catalog.** 1.5.0 (301) printed the raw key
    /// `daily.action.viewSteps` on the "steps below your usual pace" card,
    /// because the catalog had no entry for it.
    @Suite("Digest action labels: every server key resolves")
    struct DigestActionKeysTests {
        /// `git grep -ho "daily\.action\.[A-Za-z]*"` in the server repo at v1.47.1.
        static let serverKeys = [
            "daily.action.checkinAdjust", "daily.action.checkinKeep", "daily.action.checkinLetGo",
            "daily.action.logDose", "daily.action.reconnect", "daily.action.viewAppointment",
            "daily.action.viewAppointments", "daily.action.viewCheckups", "daily.action.viewEcg",
            "daily.action.viewMilestone", "daily.action.viewPulse", "daily.action.viewSteps"
        ]

        private static func bundle(for locale: String) -> Bundle? {
            let main = Bundle(for: AppContainer.self)
            return main.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:))
        }

        @Test("de, en and nl carry every server label key")
        func catalogCarriesServerKeys() throws {
            for locale in ["de", "en", "nl"] {
                let bundle = try #require(Self.bundle(for: locale), "\(locale).lproj")
                for key in Self.serverKeys {
                    let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
                    #expect(value != "\u{0}" && value != key, "\(locale): \(key) missing")
                }
            }
            let de = try #require(Self.bundle(for: "de"))
            #expect(de.localizedString(forKey: "daily.action.viewSteps", value: nil, table: nil) == "Schritte ansehen")
        }

        @Test("an unknown key never reaches the button as a raw key")
        func unknownKeyFallsBack() {
            let label = TodayHeroCopy.actionLabel("daily.action.someFutureThing")
            #expect(label != "daily.action.someFutureThing")
            #expect(label == TodayHeroCopy.actionLabel(TodayHeroCopy.fallbackActionKey))
            #expect(!TodayHeroCopy.actionLabel(String()).isEmpty)
        }

        @Test("steps.view opens the steps insight")
        func stepsRoute() {
            #expect(TodayHeroActionRoute.resolve(intent: "steps.view", href: "/insights/steps") == .insights(slug: "steps"))
        }
    }
#endif
