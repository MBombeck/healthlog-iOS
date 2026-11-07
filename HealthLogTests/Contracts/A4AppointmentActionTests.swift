// App-target symbols (`TodayHeroActionRoute`, `TodayHeroCopy`) are not in the
// SPM library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **A4 (iOS 1.4) — the appointment action (#149), required before
    /// server 1.44.0.**
    ///
    /// 1.43.11 keeps `intent: "checkup.view"` and moves `href` to
    /// `/checkups?visit=<id>` (one visit) or `/checkups?view=visits` (several);
    /// 1.44.0 switches to `intent: "visit.view"` with `labelKey`
    /// `daily.action.viewAppointment` / `daily.action.viewAppointments`. The
    /// appointment push `url` becomes `/checkups?visit=<id>`. The app has no
    /// visit screen, so every one of these opens the Vorsorge list, as the
    /// appointment did before.
    @Suite("A4: appointment action and push (#149)")
    struct A4AppointmentActionTests {
        static let digestJSON = #"""
        {"generatedAt":"2026-10-21T08:00:00.000Z","phase":"final","sleepPending":false,
         "score":null,"topSignal":null,"briefingLead":null,"line":"A steady day so far.",
         "worthALook":[
          {"kind":"upcoming_visit","title":"Appointment coming up","body":"Dr. Weber today",
           "status":"info","actions":[{"labelKey":"daily.action.viewAppointment","intent":"visit.view",
           "href":"/checkups?visit=enc_7f3a"}]},
          {"kind":"upcoming_visit","title":"Appointments coming up","body":"Two this week",
           "status":"info","actions":[{"labelKey":"daily.action.viewAppointments","intent":"visit.view",
           "href":"/checkups?view=visits"}]},
          {"kind":"upcoming_visit","title":"Appointment coming up","body":"Dr. Weber tomorrow",
           "status":"info","actions":[{"labelKey":"daily.action.viewCheckups","intent":"checkup.view",
           "href":"/checkups?visit=enc_7f3a"}]}
         ]}
        """#

        @Test("visit.view opens the Vorsorge list for one visit and for several; the label resolves")
        func visitViewRoutes() throws {
            let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(Self.digestJSON.utf8))
            let actions = digest.rail.flatMap(\.boundedActions)
            #expect(actions.count == 3)
            for action in actions.prefix(2) {
                #expect(TodayHeroCopy.actionLabel(action.labelKey) != action.labelKey, "label key resolves")
            }
            // 1.5 VISIT — one named visit opens Vorsorge with that visit,
            // several open it with the soonest.
            #expect(TodayHeroActionRoute.resolve(intent: actions[0].intent, href: actions[0].href) == .visit(id: "enc_7f3a"))
            #expect(TodayHeroActionRoute.resolve(intent: actions[1].intent, href: actions[1].href) == .checkupsList)
            // 1.43.11: the old intent with the new href keeps its front door.
            #expect(TodayHeroActionRoute.resolve(intent: actions[2].intent, href: actions[2].href) == .checkupFrontDoor)
        }

        @Test("the other intents route as before")
        func otherIntentsUnchanged() {
            typealias Route = TodayHeroActionRoute
            #expect(Route.resolve(intent: "coach.checkin.keep:plan_1", href: nil) == .coachKeep(planId: "plan_1"))
            #expect(Route.resolve(intent: "coach.checkin.letGo:plan_1", href: nil) == .coachLetGo(planId: "plan_1"))
            #expect(Route.resolve(intent: "coach.checkin.keep:", href: nil) == .none)
            #expect(Route.resolve(intent: "coach.checkin.adjust", href: nil) == .coach)
            #expect(Route.resolve(intent: "dose.log", href: "/medications?highlight=m1") == .intakes)
            #expect(Route.resolve(intent: "sync.reconnect", href: nil) == .integrations)
            #expect(Route.resolve(intent: "ecg.view", href: nil) == .insightsOverview)
            #expect(Route.resolve(intent: "pulse.view", href: "/insights/pulse") == .insights(slug: "pulse"))
            #expect(Route.resolve(intent: "milestone.view", href: nil) == .insightsOverview)
            #expect(Route.resolve(intent: "future.view", href: "/insights#sleep") == .insights(slug: "sleep"))
            #expect(Route.resolve(intent: "future.view", href: "/checkups") == .none)
        }

        @Test("the appointment push opens the Vorsorge list")
        func appointmentPush() {
            #expect(DeepLinkRoute.fromPushPath("/checkups?visit=enc_7f3a") == .checkupsVisit(id: "enc_7f3a"))
            #expect(DeepLinkRoute.fromPushPath("/checkups?view=visits") == .checkups)
            #expect(DeepLinkRoute.fromPushPath("/checkups") == .checkups)
        }

        // MARK: - Every string A4 adds, in both catalog languages

        static let keys: [(key: String, specifiers: [String])] = [
            ("daily.action.viewAppointment", []),
            ("daily.action.viewAppointments", []),
            ("sleep.split.nightAndNaps %@ %@", ["%1$@", "%2$@"]),
            ("sleep.split.napsOnly", []),
            ("sleep.score.gap.fewNights %lld %lld", ["%1$lld", "%2$lld"]),
            ("sleep.score.gap.fewNightsPlain", []),
            ("sleep.score.gap.noMainSleep", []),
            ("settings.hkdiag.freshness_entered_here %@", ["%@"])
        ]

        private static func bundle(for locale: String) -> Bundle? {
            let main = Bundle(for: AppContainer.self)
            return main.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:))
        }

        @Test("de and en carry every new key, its arguments, and none of the banned glyphs")
        func catalog() throws {
            let expected = [
                "daily.action.viewAppointment": ("Termin ansehen", "View appointment"),
                "daily.action.viewAppointments": ("Termine ansehen", "View appointments")
            ]
            for locale in ["de", "en"] {
                let bundle = try #require(Self.bundle(for: locale), "\(locale).lproj")
                for entry in Self.keys {
                    let value = bundle.localizedString(forKey: entry.key, value: "\u{0}", table: nil)
                    #expect(value != "\u{0}" && value != entry.key, "\(locale): \(entry.key) missing")
                    for specifier in entry.specifiers {
                        #expect(value.contains(specifier), "\(locale): \(entry.key) lost \(specifier)")
                    }
                    for glyph in ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}"] {
                        #expect(!value.contains(glyph), "\(locale): \(entry.key)")
                    }
                    if let pair = expected[entry.key] {
                        #expect(value == (locale == "de" ? pair.0 : pair.1))
                    }
                }
            }
        }
    }
#endif
