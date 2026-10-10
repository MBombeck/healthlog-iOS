import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable file_length type_body_length

/// Server v1.42.0 plus the v1.40 to v1.41 contract changes:
/// every response the app reads whose closed enums or shapes grew, fed through
/// the decoder the app actually uses.
///
/// **Fixture source.** `MBombeck/HealthLog` `docs/api/openapi.yaml` on
/// `release/v1.42.0` at `402c50378` (2026-10-09; no `v1.42.0` tag existed yet).
/// Each payload is an instance of the named schema with every required field
/// present and the new values filled in: `AccountPayload`, `EnvironmentOverview`,
/// `DailyDigest`, `AuthProfileUpdateResponse` (`ValidationIssue`),
/// `MedicationListEntry` (`MedicationCourse`), `InboundDocument.kind`, and the
/// `CoachStreamEvent` frames. Nothing here is a shape the document does not
/// describe.
@Suite("Server contract v1.42 decode (#123)")
struct ServerContractV142DecodeTests {
    // MARK: - GET /api/auth/me (AccountPayload)

    /// `AccountPayload` at v1.42: `timezone`, `glucoseUnit`, `features`,
    /// `coachReasoning` (v1.41), `moduleAccess.timeline` (v1.42), and the
    /// documented additional `modules` map.
    static let accountPayload = Data(#"""
    {
      "id": "u_1", "username": "alex",
      "timezone": "Europe/Berlin",
      "glucoseUnit": "mmol/L",
      "features": { "trackIntake": true },
      "accountAccess": { "accounts": [], "active": null, "recordKind": "self", "canSwitch": false },
      "modules": { "weight": true, "environment": true, "timeline": false },
      "moduleAccess": {
        "cycle": "enabled", "mood": "enabled", "sleep": "enabled", "glucose": "enabled",
        "workouts": "enabled", "recovery": "enabled", "labs": "enabled", "illness": "disabled",
        "achievements": "enabled", "coach": "enabled", "insights": "enabled", "medications": "enabled",
        "doctorReport": "enabled", "environment": "enabled", "mcp": "unavailable",
        "inboundDocuments": "enabled", "mentalHealth": "enabled", "nutrients": "enabled",
        "vaccinations": "enabled", "timeline": "disabled"
      },
      "ai": {
        "capabilities": {
          "coach": { "available": true, "reason": null, "onDeviceAllowed": true },
          "briefing": { "available": true, "reason": null, "onDeviceAllowed": true },
          "periodNarrative": { "available": true, "reason": null, "onDeviceAllowed": true },
          "statusText": { "available": false, "reason": "user_disabled", "onDeviceAllowed": false },
          "workoutInsights": { "available": true, "reason": null, "onDeviceAllowed": true },
          "reactionLines": { "available": true, "reason": null, "onDeviceAllowed": true },
          "aboutMeQuestions": { "available": true, "reason": null, "onDeviceAllowed": true },
          "documentAi": { "available": false, "reason": "consent_required", "onDeviceAllowed": true },
          "labsOcr": { "available": true, "reason": null, "onDeviceAllowed": true },
          "medicationExtract": { "available": true, "reason": null, "onDeviceAllowed": true }
        },
        "provider": { "configured": true, "managedBy": "server", "canConfigure": false, "responseTimeoutMs": 60000 }
      },
      "coachReasoning": {
        "level": "low", "preference": "medium", "maxLevel": "low",
        "available": true, "offIsReal": false, "source": "admin_cap"
      },
      "recordSession": null,
      "notificationPrefs": { "medication": { "clientManaged": true } },
      "onboarding": {
        "steps": [],
        "needs": {
          "recordTarget": null, "areas": [], "medication": null, "sources": [], "visit": null,
          "units": { "glucoseUnit": null, "unitPreference": null }
        },
        "completedAt": null,
        "firstResult": null
      }
    }
    """#.utf8)

    @Test("/me: the session user decodes with the v1.42 additions beside it")
    func meUser() throws {
        let user = try JSONDecoder.hlDefault.decode(User.self, from: Self.accountPayload)
        #expect(user.id == "u_1")
        #expect(user.username == "alex")
        #expect(user.accountAccessStatus == .valid)
    }

    @Test("/me: the server's resolved timezone and glucose unit reach the settings mirror")
    func meServerPrefs() throws {
        let prefs = try JSONDecoder.hlDefault.decode(AuthMeServerPrefs.self, from: Self.accountPayload)
        #expect(prefs.timezone == "Europe/Berlin")
        #expect(prefs.glucoseUnit == "mmol/L")
        #expect(prefs.glucoseUnitPresent)
        #expect(prefs.medicationReminderDelivery?.clientManaged == true)
    }

    @Test("/me: the module map keeps every known module when `timeline` arrives")
    func meModules() throws {
        let state = try JSONDecoder.hlDefault.decode(AuthMeModules.self, from: Self.accountPayload)
        #expect(state.modules?["weight"] == true)
        #expect(state.moduleAccess?["illness"] == .disabled)
        #expect(state.moduleAccess?["timeline"] == .disabled)
        #expect(state.moduleAccess?.count == 20)
        #expect(state.ai != nil, "coachReasoning and features beside it cost nothing")
        // `timeline` is not a module this build offers: no toggle appears for it.
        #expect(ModuleKey(rawValue: "timeline") == nil)
    }

    // MARK: - GET /api/environment (EnvironmentOverview)

    @Test("/api/environment: lat/lon null, airQuality, latestDay and attributions decode")
    func environmentOverview() throws {
        // `EnvironmentHome.lat`/`lon` are `number` in the document, but the #123
        // brief says they may be null now that locations are encrypted at rest;
        // the app decodes them optional either way.
        let json = Data(#"""
        {
          "home": { "lat": null, "lon": null, "label": null, "timezone": "Europe/Berlin", "since": null },
          "travel": [
            { "id": "t1", "startDate": "2026-09-01", "endDate": "2026-09-07", "lat": 43.7, "lon": 7.3, "label": "Nizza" }
          ],
          "context": { "days": 412, "latestDate": "2026-10-07", "latestFetchedAt": "2026-10-08T03:12:00Z" },
          "lastFetchFailure": null,
          "attribution": "Weather data by Open-Meteo.com",
          "airQuality": {
            "enabled": true, "operatorDisabled": false, "days": 380,
            "latestDate": "2026-10-07", "domain": "cams_europe"
          },
          "latestDay": {
            "date": "2026-10-07", "tempMin": 8.1, "tempMax": 16.4, "apparentMax": 15.2,
            "airQuality": {
              "pm25Mean": 7.2, "pm10Mean": 12.9, "no2Mean": null, "o3Max8h": 61.0,
              "eaqiMax": 2, "uvIndexMax": 3.1, "dustMax": null,
              "pollen": { "alder": null, "birch": 0, "grass": 4.5, "mugwort": null, "olive": null, "ragweed": 0 }
            }
          },
          "attributions": ["Weather data by Open-Meteo.com", "Air quality: Copernicus Atmosphere Monitoring Service"]
        }
        """#.utf8)
        let overview = try JSONDecoder.hlDefault.decode(EnvironmentOverviewDTO.self, from: json)
        let home = try #require(overview.home)
        #expect(home.lat == nil)
        #expect(home.lon == nil)
        #expect(home.timezone == "Europe/Berlin")
        #expect(overview.travel.count == 1)
        #expect(overview.context.days == 412)
        #expect(overview.attribution == "Weather data by Open-Meteo.com")
    }

    // MARK: - GET /api/daily/digest (DailyDigest, v1.40.2 and v1.40.3 fields)

    @Test("/api/daily/digest: lead, today, restMode, signalLine and the steady-score fields decode")
    func dailyDigest() throws {
        let json = Data(#"""
        {
          "generatedAt": "2026-10-09T06:00:00Z", "phase": "final", "sleepPending": false,
          "score": {
            "value": 74, "band": "green", "delta": null, "configured": false, "deltaReason": null,
            "scoreVersion": 3, "composition": ["heart", "sleep"], "steadyWeeks": 3, "steadyAtLeast": false
          },
          "topSignal": { "sourceMetric": "resting_hr", "tone": "watch", "headline": "Ruhepuls höher", "nudge": "Heute ruhiger angehen", "delta": "+4 bpm" },
          "briefingLead": null,
          "lead": { "text": "Dein Ruhepuls liegt über deinem Üblichen.", "source": "signal" },
          "signalLine": { "headline": null, "delta": "+4 bpm" },
          "today": [
            { "kind": "medications", "label": "Medikamente", "value": "2 von 3", "href": "/medications", "moduleKey": "medications" },
            { "kind": "rest_mode", "label": "Schonmodus", "value": "Tag 2", "href": "/illness" }
          ],
          "restMode": { "day": 2 },
          "line": "Dein Tag in HealthLog",
          "worthALook": [],
          "justIn": null,
          "reactionLine": null,
          "ai": {
            "briefing": { "available": true, "reason": null, "onDeviceAllowed": true },
            "coach": { "available": true, "reason": null, "onDeviceAllowed": true },
            "reactionLines": { "available": false, "reason": "no_provider", "onDeviceAllowed": true }
          }
        }
        """#.utf8)
        let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: json)
        #expect(digest.phase == "final")
        #expect(digest.score?.value == 74)
        #expect(digest.score?.delta == nil)
        #expect(digest.topSignal?.delta == "+4 bpm")
        #expect(digest.line == "Dein Tag in HealthLog")
        #expect(digest.ai?.reactionLines?.available == false)
    }

    // MARK: - PUT /api/auth/profile (rejectedFields as ValidationIssue)

    @Test("rejectedFields: ValidationIssue items with `keys` decode, the keys are ignored")
    func rejectedFieldsWithKeys() throws {
        let json = Data(#"""
        {
          "id": "u_1", "username": "alex", "email": "alex@example.org", "role": "USER",
          "heightCm": 182, "dateOfBirth": null, "gender": null, "timezone": "Europe/Berlin",
          "fullName": null, "insurerName": null, "insurerIkNumber": null, "hasInsuranceNumber": false,
          "rejectedFields": [
            { "path": "", "code": "unrecognized_keys", "message": "Unrecognized key(s) in object", "keys": ["nickname", "shoeSize"] },
            { "path": "heightCm", "code": "too_big", "message": "Number must be less than or equal to 300" }
          ]
        }
        """#.utf8)
        let result = try JSONDecoder.hlDefault.decode(ProfilePatchResult.self, from: json)
        #expect(result.isPartial)
        #expect(result.rejectedFields.map(\.code) == ["unrecognized_keys", "too_big"])
        #expect(result.rejectedFields.last?.path == "heightCm")
    }

    // MARK: - GET /api/medications (MedicationListEntry, v1.40 courses and custom categories)

    static let customCategoryMedication = Data(#"""
    {
      "id": "med_1", "name": "Vitamin D", "dose": "1000 IE", "treatmentClass": "GENERIC",
      "dosesPerUnit": null, "unitsPerDose": 1, "reorderLeadDays": null, "active": true,
      "notificationsEnabled": true, "liveActivityEnabled": false, "criticalAlarmEnabled": false,
      "atcCode": null, "rxNormCode": null, "pausedAt": null, "snoozedUntil": null,
      "nextDueAt": null, "nextDueOverdue": false, "startsOn": "2026-03-01", "endsOn": null,
      "oneShot": false, "asNeeded": false, "trackIntake": true,
      "createdAt": "2026-03-01T08:00:00.000Z", "updatedAt": "2026-10-01T08:00:00.000Z",
      "schedules": [],
      "category": "custom:5b1f2c4e-9a7d-4e21-8f0a-2c9d1e6b7a30",
      "categoryLabel": "Winterkur",
      "courses": [
        { "id": "c1", "startsOn": "2025-11-01", "endsOn": "2026-02-28", "status": "ENDED", "takenDoses": 118, "note": null },
        { "id": "c2", "startsOn": "2026-03-01", "endsOn": null, "status": "CURRENT", "takenDoses": 210, "note": "zweiter Winter" }
      ],
      "courseCount": 2, "previousCourseEndedOn": "2026-02-28", "canStartCourse": false,
      "externalSource": null, "courseStatus": "CURRENT", "intakeActionable": true,
      "lastTakenAt": null, "todayEventCount": 1,
      "stockUnitsRemaining": null, "stockDosesRemaining": null, "runwayDays": null
    }
    """#.utf8)

    @Test("medications: courses and a custom category decode, and the label is the server's")
    func medicationCustomCategory() throws {
        let wire = try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Self.customCategoryMedication)
        #expect(wire.category == "custom:5b1f2c4e-9a7d-4e21-8f0a-2c9d1e6b7a30")
        #expect(wire.categoryLabel == "Winterkur")
        #expect(wire.courseStatus == .current)
        let medication = wire.toDomain()
        #expect(medication.categoryLabel == "Winterkur")
        // The raw key never reaches the screen.
        let shown = try MedicationCard.localizedCategory(#require(medication.category), label: medication.categoryLabel)
        #expect(shown == "Winterkur")
        // A copy made field by field (the editor opens on one) keeps the label.
        #expect(medication.replacingSchedule(medication.schedule).categoryLabel == "Winterkur")
    }

    @Test("medications: a built-in category still reads from the catalogue, a label-less custom key reads neutral")
    func medicationCategoryFallbacks() {
        #expect(MedicationCard.localizedCategory("VITAMIN", label: nil) == MedicationCard.localizedCategory("VITAMIN"))
        let unlabelled = MedicationCard.localizedCategory("custom:abc", label: nil)
        #expect(unlabelled == String(localized: "medications.categoryCustom"))
        #expect(!unlabelled.contains("abc"))
    }

    // MARK: - Documents (InboundDocument.kind, v1.40 SICK_NOTE)

    @Test("documents: SICK_NOTE is its own kind with a label and an icon, not Other")
    func sickNoteKind() throws {
        let kind = try JSONDecoder().decode(DocumentKind.self, from: Data(#""SICK_NOTE""#.utf8))
        #expect(kind == .sickNote)
        #expect(DocumentKindMeta.order.contains(.sickNote))
        #expect(DocumentKindMeta.order.last == .other)
        #expect(DocumentKindMeta.icon(.sickNote) != DocumentKindMeta.icon(.other))
        let unknown = try JSONDecoder().decode(DocumentKind.self, from: Data(#""SOMETHING_LATER""#.utf8))
        #expect(unknown == .other)
    }

    // MARK: - POST /api/insights/chat (CoachStreamEvent, v1.41 and v1.42 frames)

    /// One full v1.42 turn in the documented order: `(activity | step | interim
    /// result)* → token* → provenance → result* → memoryNote? → planProposal? →
    /// followUps? → done`. The step and the table frames use the v1.42 tool
    /// `get_day` / `get_environment` and the domains `day` / `environment`;
    /// the done frame carries v1.41 `stop` and `withheldResults`.
    static let coachTurn: String = {
        // One frame per raw literal; line breaks inside a literal are dropped
        // so every frame goes out as one `data:` line.
        let frames = [
            #"""
            {"type":"activity","activity":{"id":"a1","phase":"thinking","status":"running","round":1,
            "labelKey":"coach.activity.thinking","label":"Denkt nach"}}
            """#,
            #"""
            {"type":"step","step":{"id":"s1","tool":"get_day","labelKey":"coach.step.day","label":"Tag lesen",
            "domain":"day","status":"done","count":12,"day":"2026-10-08"}}
            """#,
            #"""
            {"type":"step","step":{"id":"s2","tool":"get_environment","labelKey":"coach.step.environment",
            "label":"Umwelt lesen","domain":"environment","window":"last30days","status":"empty","reason":"no_data"}}
            """#,
            #"""
            {"type":"result","interim":true,"result":{"ref":"r1","source":{"tool":"get_environment",
            "domain":"environment","window":"last30days","period":"current"},"shape":"single",
            "titleKey":"coach.result.environment","title":"Umwelt","rowCount":0,"chartKind":"compare",
            "displayed":true,"columns":[],"rows":[],"truncated":false,"chart":null}}
            """#,
            #"""
            {"type":"activity","activity":{"id":"a1","phase":"stop","status":"done","round":2,
            "labelKey":"coach.activity.stop","label":"Fertig","stop":"cap"}}
            """#,
            #"{"type":"token","token":"Gestern "}"#,
            #"{"type":"token","token":"war ruhig."}"#,
            #"""
            {"type":"provenance","metricSource":{"windows":["last30days"],"metrics":["pulse"],"counts":{"pulse":42},
            "steps":[{"id":"s1","tool":"get_day","labelKey":"coach.step.day","label":"Tag lesen","domain":"day",
            "status":"done"}],"activity":[],"stop":{"reason":"cap","rounds":2},"assumptions":[]}}
            """#,
            #"""
            {"type":"memoryNote","note":{"proposal":true,"proposalId":"p1","category":"goal","fact":"Mehr schlafen"}}
            """#,
            #"""
            {"type":"planProposal","proposal":{"planId":"pl1","metric":"sleep","reviewInDays":14,
            "ifCue":"nach 22 Uhr","thenAction":"Bildschirm aus"}}
            """#,
            #"""
            {"type":"clarification","clarification":{"kind":"comparison","choices":[{"id":"c1",
            "labelKey":"coach.choice.previous","label":"Vorperiode","value":{"comparison":"previous_period"}}],
            "freeText":false}}
            """#,
            #"""
            {"type":"followUps","followUps":[{"id":"f1","kind":"change_assumption",
            "labelKey":"coach.followup.change","label":"Annahme ändern"}]}
            """#,
            #"""
            {"type":"done","conversationId":"conv_1","messageId":"msg_9","stop":{"reason":"cap","rounds":2},
            "withheldResults":true}
            """#
        ]
        return frames
            .map { "data: \($0.replacingOccurrences(of: "\n", with: ""))\n\n" }
            .joined()
    }()

    @Test("coach stream: new frames and enum values never break the turn")
    func coachStream() throws {
        let reply = try CoachServerService.parseSSE(Data(Self.coachTurn.utf8))
        #expect(reply.text == "Gestern war ruhig.")
        #expect(reply.conversationId == "conv_1")
        #expect(reply.messageId == "msg_9")
        let provenance = try #require(reply.provenance)
        #expect(provenance.windows == ["last30days"])
        #expect(provenance.metrics == ["pulse"])
        #expect(provenance.counts?["pulse"] == 42)
    }
}

// swiftlint:enable file_length type_body_length
