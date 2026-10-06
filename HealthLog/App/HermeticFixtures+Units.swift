#if DEBUG
    import Foundation

    extension HermeticUITestSupport {
        /// **#115 P2.** `-uitest-imperial` — the imperial-account overlay. Only
        /// the QA sweep's `test_12_imperialUnits` passes it, and only together
        /// with `-uitest-sweep`.
        static let imperialOverlayArgument = "-uitest-imperial"

        static var isImperialOverlayActive: Bool {
            isSweepOverlayActive && ProcessInfo.processInfo.arguments.contains(imperialOverlayArgument)
        }
    }

    /// **#115 P2 — the TestFlight 284 world: an imperial account with a weight
    /// target.**
    ///
    /// `/api/auth/me` answers `unitPreference: "imperial"` (so the app adopts the
    /// account's unit system exactly as it does from a real server), and
    /// `/api/insights/targets` answers a canonical kilogram weight band,
    /// 61.9–83.3 kg with every one of the last 30 days in range — the numbers in
    /// the tester's screenshot. Everything else falls through to the sweep and
    /// marketing tables. Invented values only.
    enum ImperialUnitFixtures {
        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            if path == "/api/auth/me" { return ok(meJSON) }
            if path == "/api/insights/targets" { return ok(targetsJSON) }
            return nil
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        /// The shared hermetic identity (ids, acknowledged disclaimer, finished
        /// tour) plus the account's unit system.
        static let meJSON = """
        {
          "id": "hermetic-user",
          "email": "hermetic@uitest.local",
          "username": "hermetic",
          "displayName": "Emma Weber",
          "createdAt": "2024-01-01T00:00:00.000Z",
          "disclaimerAcknowledgedAt": "2024-01-01T00:00:00.000Z",
          "onboardingTourCompleted": true,
          "moodReminderEnabled": false,
          "unitPreference": "imperial"
        }
        """

        /// Canonical kg on the wire, as the server sends it.
        static let targetsJSON = """
        {
          "targets": [
            {
              "type": "WEIGHT", "label": "Weight", "current": 72.4, "average30": 72.5, "trend": "stable",
              "unit": "kg", "range": { "min": 61.9, "max": 83.3 },
              "classification": { "category": "Optimal", "color": "var(--success)" },
              "source": "BMI 18.5–24.9", "daysInRange7d": 7, "daysLogged7d": 7,
              "daysInRange30d": 30, "daysLogged30d": 30, "lastMetGoalAt": null, "streakDays": 30,
              "insufficientData": false, "consistency7d": ["in", "in", "in", "in", "in", "in", "in"]
            }
          ],
          "pageSummary": { "targetsMetThisWeek": 1, "totalTargets": 1, "streakHighlight": null },
          "bpDiastolic": null,
          "profile": null
        }
        """
    }
#endif
