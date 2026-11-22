#if DEBUG
    import Foundation

    /// **12-12 second pass — the marketing-capture fixture overlay.**
    ///
    /// Active only under `-uitest-marketing`, which only
    /// `MarketingScreenshotsTest` passes. The shared hermetic table serves an
    /// EMPTY medication world (`/api/medications` → `[]`) on purpose: the
    /// Phase-8 accessibility audit pins the dashboard states that world
    /// produces, and the walkthrough tests assert against it. The README
    /// screenshots, however, should show the compliance card and the
    /// medications list doing their job — so this overlay answers exactly the
    /// routes that world needs and returns `nil` for everything else, leaving
    /// the shared table byte-identical for every other test.
    ///
    /// **Register.** The three medications are the public mirror's own
    /// substitution vocabulary (Lisinopril / Trulicity / Naproxen). Doses,
    /// schedules, stock counts and intake states are invented and deliberately
    /// unremarkable — nothing in this file resembles any real person's
    /// regimen, and no health value of any real person appears in this
    /// repository's fixtures.
    ///
    /// **Why server-emitted intake rows instead of client synthesis.** The
    /// hermetic boot never records a `MedicationSlotMaterializationGate`
    /// verdict (`/api/version` is not served), and an unknown verdict means
    /// "do not synthesise" — so schedule-derived placeholders would never
    /// materialise. The overlay therefore serves
    /// `GET /api/medications/intake?scope=today` rows itself, computed against
    /// the simulator's own calendar day so `ComplianceSnapshot.reconciled`
    /// (which buckets strictly by "today" and, once medications are loaded,
    /// trusts the local view over the server summary) counts them. Every
    /// time is relative to now and comes from `AreaMedsDetailFixtures`, the
    /// history the detail reads as well, so list, detail and ring agree: later
    /// in the day two doses are taken and one is open (2/3); before eight the
    /// morning doses are still to come and the last intake is yesterday's.
    ///
    /// **Greeting.** `/api/dashboard/summary` is re-served with an EMPTY
    /// salutation so `DashboardHeader` renders its bare "Hi" fallback instead
    /// of "Hermetic Tester" on the hero shot. Fixture-side on purpose — the
    /// production greeting logic is untouched.
    ///
    /// **Avatar (third pass).** The hero shot's header avatar used to render
    /// the bare `"?"` monogram (the shared world serves `{}` on
    /// `/api/user/profile`, so there is neither a photo nor initials). The
    /// overlay now serves a profile whose `avatarUrl` points back into the
    /// fixture host, and answers that `/api/user/avatar/…` family with the
    /// PNG bytes of a **synthetic, AI-generated portrait — no real person**
    /// (`marketing-avatar.png`, a `HealthLogUITests` bundle resource whose
    /// absolute path `MarketingScreenshotsTest` hands over via
    /// ``avatarPathArgument``; the simulator shares the host filesystem, the
    /// same seam the capture writer uses). The bytes ride the REAL display
    /// pipeline — `AvatarRepository.fetchImageData` through the pinned
    /// client, `AvatarStore`'s bounded ImageIO thumbnail — so the
    /// shot shows the product path, not a mock. The profile's display name
    /// ("Emma Weber", as synthetic as the photo) keeps any name-showing
    /// surface coherent with it; the GREETING is untouched — it reads the
    /// summary's salutation, which stays empty, so the hero line remains the
    /// bare "Hi". A missing/unreadable resource answers 404, which the
    /// pipeline honestly renders as the initials monogram.
    enum MarketingFixtures {
        /// Launch argument carrying the absolute path of the synthetic
        /// portrait inside the UITest runner's bundle. Only
        /// `MarketingScreenshotsTest` passes it.
        static let avatarPathArgument = "-uitest-marketing-avatar"

        static func response(
            forPath path: String,
            method: String,
            query: [URLQueryItem] = []
        ) -> (status: Int, body: Data)? {
            // Recently deleted documents (`-uitest-docs-trash`).
            // 1.5 SHOTS — the LAB-DOC surfaces for the picture sweep (`-uitest-lab-doc`).
            // The account routes every other sweep boot shares (`sweepAccountResponse`).
            // Server 1.48 on the app side (`-uitest-server148`), above the sweep.
            // Server 1.49 part B (`-uitest-catchup-b`): its reads and the refused target.
            if let overlay = Server148Fixtures.response(forPath: path, method: method, query: query)
                ?? CatchupBFixtures.response(forPath: path, method: method)
                ?? CatchupAFixtures.response(forPath: path, method: method, query: query)
                ?? DocsTrashFixtures.response(forPath: path, method: method)
                ?? LabDocFixtures.response(forPath: path, method: method)
                ?? sweepAccountResponse(forPath: path, method: method, query: query) { return overlay }
            // 1.5 VERDICTS — the server-judged trends (`-uitest-verdicts`).
            if HermeticUITestSupport.isVerdictsOverlayActive,
               let verdicts = VerdictFixtures.response(forPath: path, method: method, query: query)
            {
                return verdicts
            }
            // iOS 1.4 B2-b — the medications-and-mood overlay of the sweep
            // (`-uitest-area-meds`) rides on this world and outranks it.
            if HermeticUITestSupport.isAreaMedsOverlayActive,
               let area = AreaMedsFixtures.response(forPath: path, method: method, query: query)
            {
                return area
            }
            guard method == "GET" else { return nil }
            // The recovery and HRV pages' wearable readings, only
            // under `-uitest-recovery` (never during the App Store motifs).
            if HermeticUITestSupport.isRecoveryOverlayActive,
               let recovery = RecoveryFixtures.response(forPath: path, method: method, query: query)
            {
                return recovery
            }
            // The imperial-account overlay (`-uitest-imperial`) outranks
            // this table's `/me`.
            if HermeticUITestSupport.isImperialOverlayActive,
               let imperial = ImperialUnitFixtures.response(forPath: path, method: method)
            {
                return imperial
            }
            if path.hasPrefix("/api/dashboard/summary") {
                return ok(summaryJSON)
            }
            // Order matters: the intake route sits under the list route's prefix.
            if path.hasPrefix("/api/medications/intake") { return ok(todayIntakesJSON) }
            // The list, and the single read behind a
            // medication's "Related" section: the list's own row, without
            // relations. Before, the list's prefix answered it with `[]` and
            // the section showed its error.
            if let medications = path == "/api/medications" ? medicationsJSON : singleMedicationJSON(forPath: path) {
                return ok(medications)
            }
            if path.hasPrefix("/api/user/avatar/") { return avatarResponse() }
            if path == "/api/user/profile" { return ok(profileJSON) }
            // Exact match — `/api/auth/me/modules` and the report-selection
            // route live under this prefix and must keep their shared answers.
            if path == "/api/auth/me" { return ok(meJSON) }
            // Everything else — layout, compliance, per-id routes, the whole
            // rest of the API — falls through to the shared hermetic table.
            return nil
        }

        /// The rest of the sweep shares the medications world's per-medication
        /// routes, notification settings and cycle, so a detail,
        /// Benachrichtigungen or Zyklus opened there reads like a real account
        /// instead of failing on the empty default. Today's intake rows stay
        /// this table's. `nil` outside the sweep and under `-uitest-area-meds`,
        /// whose own table answers the same routes after its overlays.
        private static func sweepAccountResponse(
            forPath path: String,
            method: String,
            query: [URLQueryItem]
        ) -> (status: Int, body: Data)? {
            guard HermeticUITestSupport.isSweepOverlayActive, !HermeticUITestSupport.isAreaMedsOverlayActive,
                  path != "/api/medications/intake" else { return nil }
            return AreaMedsDetailFixtures.response(forPath: path, method: method, query: query)
                ?? AreaNotificationsFixtures.response(forPath: path, method: method)
                ?? AreaCycleFixtures.response(forPath: path, method: method)
        }

        /// Content-type override for the routes whose bodies are not JSON.
        /// Consulted by ``HermeticURLProtocol`` only while the marketing
        /// overlay is active; `nil` keeps the protocol's JSON default.
        static func contentType(forPath path: String) -> String? {
            path.hasPrefix("/api/user/avatar/") ? "image/png" : nil
        }

        /// `GET /api/medications/{id}` for an id of ``medicationsJSON``.
        private static func singleMedicationJSON(forPath path: String) -> String? {
            let prefix = "/api/medications/"
            guard path.hasPrefix(prefix) else { return nil }
            let id = String(path.dropFirst(prefix.count))
            guard !id.isEmpty, !id.contains("/"),
                  let rows = try? JSONSerialization.jsonObject(with: Data(medicationsJSON.utf8)) as? [[String: Any]],
                  let row = rows.first(where: { $0["id"] as? String == id }),
                  let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        // Stable ids the intake rows reference.
        private static let lisinoprilID = "mkshot-med-lisinopril"
        private static let naproxenID = "mkshot-med-naproxen"
        private static let trulicityID = "mkshot-med-trulicity"

        /// `GET /api/medications` — three synthetic medications (bare wire
        /// array, exactly what `MedicationsRepository.fetchMedications`
        /// decodes): a daily morning tablet, a twice-daily tablet, and a
        /// weekly injection, so the list shows the cadence range the product
        /// supports. Stock/runway values are set so the supply line renders
        /// instead of the tracking-off em-dash. `lastTakenAt` is stamped with
        /// this morning's taken slot (computed, like the intake rows) so the
        /// card's "Last intake" line agrees with the compliance bar beside it
        /// instead of showing an em-dash next to 100%. `todayEventCount` mirrors
        /// the taken 08:00 rows so `MedicationWindowStatus.reduce` does not read
        /// a taken morning dose as "very overdue" on a late-morning capture.
        static var medicationsJSON: String {
            let iso = ISO8601DateFormatter()
            /// The list's "Letzte Einnahme" and today's count, from the one
            /// invented history the detail reads too, relative to now.
            func taken(_ id: String) -> String {
                let last = AreaMedsDetailFixtures.lastTakenAt(medicationID: id).map { "\"\(iso.string(from: $0))\"" } ?? "null"
                return #""lastTakenAt": \#(last), "todayEventCount": \#(AreaMedsDetailFixtures.todayEventCount(medicationID: id))"#
            }
            return """
            [
              { "id": "\(lisinoprilID)", "name": "Lisinopril", "dose": "10 mg",
                "active": true, "notificationsEnabled": true, "deliveryForm": "ORAL",
                "stockDosesRemaining": 28, "runwayDays": 28,
                "createdAt": "2026-03-02T08:00:00.000Z", \(taken(lisinoprilID)),
                "schedules": [
                  { "windowStart": "08:00", "timesOfDay": ["08:00"], "scheduleType": "SCHEDULED" }
                ] },
              { "id": "\(naproxenID)", "name": "Naproxen", "dose": "250 mg",
                "active": true, "notificationsEnabled": true, "deliveryForm": "ORAL",
                "stockDosesRemaining": 42, "runwayDays": 21,
                "createdAt": "2026-05-11T08:00:00.000Z", \(taken(naproxenID)),
                "schedules": [
                  { "windowStart": "08:00", "timesOfDay": ["08:00", "20:00"], "scheduleType": "SCHEDULED" }
                ] },
              { "id": "\(trulicityID)", "name": "Trulicity", "dose": "\(trulicityDose)",
                "active": true, "notificationsEnabled": true, "deliveryForm": "INJECTION",
                "stockDosesRemaining": 4, "runwayDays": 28,
                "createdAt": "2026-04-06T08:00:00.000Z", \(taken(trulicityID)),
                "schedules": [
                  { "windowStart": "09:00", "timesOfDay": ["09:00"], "daysOfWeek": "1",
                    "scheduleType": "SCHEDULED" }
                ] }
            ]
            """
        }

        /// The dose is free text the user typed, so the app shows it verbatim —
        /// a German user writes "1,5 mg". The fixture follows the capture
        /// language instead of putting an English decimal point into the
        /// German App Store screenshot.
        private static var trulicityDose: String {
            // The bundle's resolved localization, like the citations overlay:
            // it is what `Text()` renders from, so dose and chrome agree.
            // German, Dutch and Spanish write a decimal comma, English and Korean a point.
            AppLanguage.current.pick(de: "1,5 mg", en: "1.5 mg", nl: "1,5 mg", ko: "1.5 mg", es: "1,5 mg")
        }

        /// `/api/dashboard/summary` with the empty salutation, re-dated to the
        /// capture day. The shared row is pinned to 2026-06-16, so the hero
        /// header read "Tuesday, Jun 16" while the Medications list beside it
        /// computes "today" / "tomorrow" and the weekly dose's next date from
        /// the real clock — two different days in one screenshot set.
        ///
        /// It also carries three more vital signs (resting heart rate, HRV,
        /// SpO₂), appended after the shared metrics. The Insights overview's
        /// "Vitals" block shows every vital with a reading, and with weight
        /// alone it ended so high that the empty insight-cards state sat under
        /// the tab bar of the App Store shot. The insight cards themselves
        /// cannot be served honestly here: `InsightsStore.load` is gated on AI
        /// consent, and the marketing run declines it. Values fit the rest of
        /// the fixture (pulse 64 on the dashboard).
        static var summaryJSON: String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let updatedAt = iso.string(from: morningSlot(hour: 7))
            let base = HermeticFixtures.dashboardSummaryJSON(salutation: "")
                .replacingOccurrences(of: "2026-06-16T08:00:00.000Z", with: iso.string(from: morningSlot(hour: 8)))
                .replacingOccurrences(of: "2026-06-16T07:00:00.000Z", with: updatedAt)
            guard var summary = (try? JSONSerialization.jsonObject(with: Data(base.utf8))) as? [String: Any],
                  let metrics = summary["metrics"] as? [[String: Any]] else { return base }
            func vital(_ kind: String, _ value: Double, _ unit: String, _ trend: String, _ series: [Double]) -> [String: Any] {
                [
                    "id": kind,
                    "kind": kind,
                    "title": kind,
                    "latestValue": value,
                    "secondaryValue": NSNull(),
                    "unit": unit,
                    "trend": trend,
                    "sparkline": series,
                    "updatedAt": updatedAt
                ]
            }
            // The server's day counters for today's intake rows. The
            // compliance ring renders these as they are; the shared table's
            // 2/1 would show 1/2 next to a medication list with three doses.
            summary["compliance"] = todayCompliance
            summary["metrics"] = metrics + [
                vital("restingHeartRate", 58, "bpm", "flat", [60, 59, 59, 58, 58]),
                vital("heartRateVariability", 46, "ms", "up", [41, 43, 42, 45, 46]),
                vital("oxygenSaturation", 97, "%", "flat", [97, 96, 97, 98, 97])
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: summary) else { return base }
            return String(bytes: data, encoding: .utf8) ?? base
        }

        /// Today at `hour`:00 in the simulator's own timezone.
        private static func morningSlot(hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        }

        /// `GET /api/medications/intake?scope=today` — today's dose rows from
        /// the same invented history as the list and the detail, taken only
        /// once their time has passed. Later in the day two morning doses are
        /// taken and the evening Naproxen is open; a capture before eight
        /// honestly shows the morning still to come.
        private static var todayIntakesJSON: String {
            let rows = AreaMedsDetailFixtures.todayIntakes()
            guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return "[]" }
            return String(bytes: data, encoding: .utf8) ?? "[]"
        }

        /// The summary's day counters, counted from ``todayIntakesJSON``'s rows.
        static var todayCompliance: [String: Int] {
            let rows = AreaMedsDetailFixtures.todayIntakes()
            return [
                "scheduledToday": rows.count,
                "takenToday": rows.count { $0["status"] as? String == "taken" }
            ]
        }

        // MARK: - Profile + avatar (third pass)

        /// The relative avatar path the profile hands the display pipeline.
        /// `AvatarRepository.splitPathAndQuery` strips the `?v=` cache-buster
        /// and the fixture router matches the remaining path family.
        private static let avatarURLPath = "/api/user/avatar/hermetic-user?v=1"

        /// `GET /api/user/profile` — decoded bare by `UserProfile` (every
        /// field optional). Carries `avatarUrl` DIRECTLY so
        /// `DashboardHeader`'s `.task(id:)` fires without waiting for the
        /// `/me` splice; the display name is the photo's synthetic identity.
        private static let profileJSON = """
        { "username": "hermetic", "displayName": "Emma Weber",
          "avatarUrl": "\(avatarURLPath)" }
        """

        /// `GET /api/auth/me` (exact) — the shared row with exactly two
        /// differences: the display name matches the synthetic portrait, and
        /// `avatarUrl` keeps the `AuthMeServerPrefs` splice coherent with the
        /// profile route. Ids, email, the acknowledged disclaimer and the
        /// completed tour stay byte-for-byte the shared world's values — the
        /// keychain-seeded `hermetic-user` identity (and the
        /// `hl.healthkit.*.hermetic-user` argument-domain keys the capture
        /// boot plants) must keep resolving. The metric `unitPreference`
        /// resets a simulator an imperial run (`-uitest-imperial`) left in lb.
        private static let meJSON = """
        {
          "id": "hermetic-user",
          "email": "hermetic@uitest.local",
          "username": "hermetic",
          "displayName": "Emma Weber",
          "avatarUrl": "\(avatarURLPath)",
          "createdAt": "2024-01-01T00:00:00.000Z",
          "disclaimerAcknowledgedAt": "2024-01-01T00:00:00.000Z",
          "onboardingTourCompleted": true,
          "moodReminderEnabled": false,
          "unitPreference": "metric"
        }
        """

        /// `GET /api/user/avatar/{userId}` — the portrait bytes, or an honest
        /// 404 (→ initials monogram) when the resource path was not handed
        /// over or does not read.
        private static func avatarResponse() -> (Int, Data) {
            guard let avatarPNG else { return (404, Data()) }
            return (200, avatarPNG)
        }

        /// The synthetic portrait's bytes, read once from the absolute path
        /// following ``avatarPathArgument`` (the UITest runner's bundled
        /// `marketing-avatar.png`; 1024 px — the upload-side maximum, which
        /// the 20-03 ImageIO thumbnail bounds on display).
        private static let avatarPNG: Data? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: avatarPathArgument),
                  arguments.index(after: index) < arguments.endIndex else { return nil }
            let path = arguments[arguments.index(after: index)]
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }()
    }
#endif
