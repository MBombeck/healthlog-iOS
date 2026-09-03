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
    /// trusts the local view over the server summary) counts them: two doses
    /// taken this morning, one evening dose still open → the ring reads 2/3.
    /// The b162 dose-safety rule means a capture run before 08:00 local would
    /// honestly read the taken doses as not-yet-due; the captures run later in
    /// the day.
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
    /// client, `AvatarStore`'s bounded ImageIO thumbnail (20-03) — so the
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

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            if path.hasPrefix("/api/dashboard/summary") {
                return ok(HermeticFixtures.dashboardSummaryJSON(salutation: ""))
            }
            // Order matters: the intake route sits under the list route's prefix.
            if path.hasPrefix("/api/medications/intake") { return ok(todayIntakesJSON) }
            if path == "/api/medications" { return ok(medicationsJSON) }
            if path.hasPrefix("/api/user/avatar/") { return avatarResponse() }
            if path == "/api/user/profile" { return ok(profileJSON) }
            // Exact match — `/api/auth/me/modules` and the report-selection
            // route live under this prefix and must keep their shared answers.
            if path == "/api/auth/me" { return ok(meJSON) }
            // Everything else — layout, compliance, per-id routes, the whole
            // rest of the API — falls through to the shared hermetic table.
            return nil
        }

        /// Content-type override for the routes whose bodies are not JSON.
        /// Consulted by ``HermeticURLProtocol`` only while the marketing
        /// overlay is active; `nil` keeps the protocol's JSON default.
        static func contentType(forPath path: String) -> String? {
            path.hasPrefix("/api/user/avatar/") ? "image/png" : nil
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
        private static var medicationsJSON: String {
            let takenAt = ISO8601DateFormatter().string(from: morningSlot(hour: 8).addingTimeInterval(300))
            return """
            [
              { "id": "\(lisinoprilID)", "name": "Lisinopril", "dose": "10 mg",
                "active": true, "notificationsEnabled": true, "deliveryForm": "ORAL",
                "stockDosesRemaining": 28, "runwayDays": 28,
                "createdAt": "2026-03-02T08:00:00.000Z", "lastTakenAt": "\(takenAt)", "todayEventCount": 1,
                "schedules": [
                  { "windowStart": "08:00", "timesOfDay": ["08:00"], "scheduleType": "SCHEDULED" }
                ] },
              { "id": "\(naproxenID)", "name": "Naproxen", "dose": "250 mg",
                "active": true, "notificationsEnabled": true, "deliveryForm": "ORAL",
                "stockDosesRemaining": 42, "runwayDays": 21,
                "createdAt": "2026-05-11T08:00:00.000Z", "lastTakenAt": "\(takenAt)", "todayEventCount": 1,
                "schedules": [
                  { "windowStart": "08:00", "timesOfDay": ["08:00", "20:00"], "scheduleType": "SCHEDULED" }
                ] },
              { "id": "\(trulicityID)", "name": "Trulicity", "dose": "1.5 mg",
                "active": true, "notificationsEnabled": true, "deliveryForm": "INJECTION",
                "stockDosesRemaining": 4, "runwayDays": 28,
                "createdAt": "2026-04-06T08:00:00.000Z",
                "schedules": [
                  { "windowStart": "09:00", "timesOfDay": ["09:00"], "daysOfWeek": "1",
                    "scheduleType": "SCHEDULED" }
                ] }
            ]
            """
        }

        /// Today at `hour`:00 in the simulator's own timezone.
        private static func morningSlot(hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        }

        /// `GET /api/medications/intake?scope=today` — today's dose rows,
        /// computed at request time against the simulator's calendar day (a
        /// static date would fall out of "today" and the reconciler would
        /// honestly report an empty day). Two morning doses taken, the
        /// evening Naproxen still pending.
        private static var todayIntakesJSON: String {
            let iso = ISO8601DateFormatter()
            func slot(hour: Int) -> Date {
                Calendar.current.date(
                    bySettingHour: hour, minute: 0, second: 0, of: .now
                ) ?? .now
            }
            func row(id: String, medication: String, at scheduledAt: Date, taken: Bool) -> String {
                let takenAt = taken
                    ? "\"\(iso.string(from: scheduledAt.addingTimeInterval(300)))\""
                    : "null"
                let status = taken ? "taken" : "pending"
                return """
                {"id":"\(id)","medicationId":"\(medication)",\
                "scheduledAt":"\(iso.string(from: scheduledAt))","takenAt":\(takenAt),\
                "status":"\(status)","snoozedUntil":null}
                """
            }
            let rows = [
                row(id: "mkshot-intake-1", medication: lisinoprilID, at: slot(hour: 8), taken: true),
                row(id: "mkshot-intake-2", medication: naproxenID, at: slot(hour: 8), taken: true),
                row(id: "mkshot-intake-3", medication: naproxenID, at: slot(hour: 20), taken: false)
            ]
            return "[\(rows.joined(separator: ","))]"
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
        /// boot plants) must keep resolving.
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
          "moodReminderEnabled": false
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
