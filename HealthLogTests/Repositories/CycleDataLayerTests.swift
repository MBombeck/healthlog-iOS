import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping force_try

/// v0.14.8 cycle marathon — locks the cycle DATA layer against the v1.15 LOCKED
/// server contract: DTO decode (incl. nulls), repo request bodies/headers
/// (externalId + Idempotency-Key), bulk per-entry result parse, 403
/// cycle.disabled handling, sync tombstone-before-upsert identity, and an Outbox
/// replay of a cycle op. Real `APIClient` + stub `URLProtocol` (no mock server).
@Suite("Cycle data layer (v1.15 LOCKED)", .serialized)
struct CycleDataLayerTests {
    private struct StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(online)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    // MARK: - DTO decode

    @Test("CycleDayLogDTO decodes full + null-tolerant")
    func decodeDayLog() throws {
        let json = Data(#"""
        {"id":"d1","date":"2026-06-01","cycleId":null,"flow":"MEDIUM",
         "intermenstrualBleeding":false,"basalBodyTempC":36.61,"ovulationTest":null,
         "cervicalMucus":"EGG_WHITE","sexualActivity":false,"protectedSex":null,
         "pregnancyTest":null,"progesteroneTest":null,"contraceptive":null,
         "symptoms":[{"key":"cramps","severity":3},{"key":"headache","severity":null}],
         "note":"hi","source":"MANUAL","externalId":"ext-1","syncVersion":2,
         "updatedAt":"2026-06-01T08:00:00.000Z","deletedAt":null}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(CycleDayLogDTO.self, from: json)
        #expect(dto.id == "d1")
        #expect(dto.flowLevel == .medium)
        #expect(dto.cervicalMucusValue == .eggWhite)
        #expect(dto.basalBodyTempC == 36.61)
        #expect(dto.symptoms.count == 2)
        #expect(dto.symptoms[1].severity == nil)
        #expect(dto.syncVersion == 2)
        #expect(dto.deletedAt == nil)
    }

    @Test("Calendar envelope + prediction decode (fertile nulls)")
    func decodeCalendar() throws {
        let json = Data(#"""
        {"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,"cyclesObserved":4},
         "prediction":{"method":"CALENDAR","nextPeriodStart":"2026-06-28",
           "nextPeriodStartLow":"2026-06-26","nextPeriodStartHigh":"2026-06-30",
           "fertileWindowStart":null,"fertileWindowEnd":null,"predictedOvulation":null,
           "ovulationConfirmed":false,"confidence":0.72,"cyclesObserved":4,
           "stillLearning":false,"disclaimer":"Schätzung"},
         "days":[{"date":"2026-06-01","phase":"MENSTRUAL","isPredictedPeriod":false,
           "isFertileWindow":false,"isPredictedOvulation":false,"isPeriodLogged":true,
           "flow":"MEDIUM","hasSymptoms":true,"confidence":0.72,"basalBodyTempC":null,
           "ovulationTest":null,"cervicalMucus":null}]}
        """#.utf8)
        let env = try JSONDecoder.hlDefault.decode(CycleCalendarResponse.self, from: json)
        #expect(env.profile?.cyclesObserved == 4)
        #expect(env.prediction?.methodValue == .calendar)
        #expect(env.prediction?.fertileWindowStart == nil)
        #expect(env.days.count == 1)
        #expect(env.days[0].phaseValue == .menstrual)
        #expect(env.days[0].isPeriodLogged)
    }

    @Test("Cycles envelope + stats decode")
    func decodeCycles() throws {
        let json = Data(#"""
        {"cycles":[{"id":"c1","startDate":"2026-05-01","endDate":null,"periodEndDate":"2026-05-05",
          "lengthDays":null,"ovulationDate":null,"ovulationConfirmed":false,"isPredicted":false,
          "syncVersion":1,"updatedAt":"2026-05-05T00:00:00.000Z"}],
         "stats":{"avgLengthDays":28,"lengthVariabilityDays":1.4,"avgPeriodLengthDays":5,"regularity":"REGULAR"}}
        """#.utf8)
        let env = try JSONDecoder.hlDefault.decode(CycleListResponse.self, from: json)
        #expect(env.cycles.count == 1)
        #expect(env.stats?.regularityValue == .regular)
        #expect(env.stats?.lengthVariabilityDays == 1.4)
    }

    @Test("Profile DTO decode")
    func decodeProfile() throws {
        let json = Data(#"""
        {"goal":"TRYING_TO_CONCEIVE","cycleTrackingEnabled":true,"rawChartMode":false,
         "predictionEnabled":true,"discreetNotifications":true,"sensitiveCategoryEncryption":true,
         "typicalCycleLength":29,"typicalPeriodLength":null,"lutealPhaseLength":13,
         "updatedAt":"2026-06-01T00:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(CycleProfileDTO.self, from: json)
        #expect(dto.goalValue == .tryingToConceive)
        #expect(dto.cycleTrackingEnabled)
        #expect(dto.typicalPeriodLength == nil)
        #expect(dto.lutealPhaseLength == 13)
    }

    @Test("Bulk per-entry results parse all four statuses")
    func decodeBulk() throws {
        let json = Data(#"""
        {"entries":[
          {"index":0,"status":"inserted","id":"a","externalId":"e0"},
          {"index":1,"status":"duplicate","externalId":"e1"},
          {"index":2,"status":"updated","id":"c","externalId":"e2"},
          {"index":3,"status":"skipped","reason":"future_date"}]}
        """#.utf8)
        let env = try JSONDecoder.hlDefault.decode(CycleBulkResponse.self, from: json)
        #expect(env.entries.map(\.status) == [.inserted, .duplicate, .updated, .skipped])
        #expect(env.entries[3].reason == "future_date")
    }

    // MARK: - Repository request shape

    @Test("logDayLog POSTs body with externalId + Idempotency-Key header")
    func logDayLogRequest() async throws {
        let repo = try CycleRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        nonisolated(unsafe) var capturedIdem: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedIdem = req.value(forHTTPHeaderField: "Idempotency-Key")
            capturedBody = req.bodyBytes()
            let body = Data(
                // swiftlint:disable:next line_length
                #"{"data":{"id":"srv-1","date":"2026-06-01","flow":"LIGHT","intermenstrualBleeding":false,"sexualActivity":false,"symptoms":[],"source":"MANUAL","externalId":"ext-9","syncVersion":0,"updatedAt":"2026-06-01T08:00:00.000Z","deletedAt":null}}"#
                    .utf8
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let write = CycleDayLogWrite(date: "2026-06-01", flow: .light, loggedAt: "2026-06-01T08:00:00Z", externalId: "ext-9")
        let dto = try await repo.logDayLog(write)
        #expect(dto.id == "srv-1")
        #expect(capturedIdem?.isEmpty == false)
        let json = try #require(capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["externalId"] as? String == "ext-9")
        #expect(json["flow"] as? String == "LIGHT")
    }

    @Test("v0.14.8 — CycleDayLogWrite encodes contraceptive when set, omits it when nil")
    func contraceptiveEncodeIfPresent() throws {
        let with = CycleDayLogWrite(
            date: "2026-06-01",
            contraceptive: .oral,
            loggedAt: "2026-06-01T08:00:00Z",
            source: "APPLE_HEALTH",
            externalId: "cycle-hk:2026-06-01"
        )
        let withJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any]
        )
        #expect(withJSON["contraceptive"] as? String == "ORAL")

        // Partial-PATCH guarantee: an unset field must be absent, never `null`
        // (the server would read an explicit null as "clear this field").
        let without = CycleDayLogWrite(date: "2026-06-01", flow: .light, loggedAt: "2026-06-01T08:00:00Z")
        let withoutJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any]
        )
        #expect(withoutJSON.index(forKey: "contraceptive") == nil)
    }

    @Test("403 cycle.disabled surfaces as a clean disabled flag, no outbox")
    func cycleDisabled403() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = CycleRepository(api: makeAPI(), outbox: outbox)
        MockURLProtocol.handler = { req in
            // v1.15 LOCKED: top-level `errorCode` (the assistant-disabled
            // precedent the iOS `APIEnvelope` already parses).
            let body = Data(#"{"data":null,"error":"cycle disabled","errorCode":"cycle.disabled"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        do {
            _ = try await repo.calendar(from: "2026-05-01", to: "2026-07-01", dayAnchor: "2026-06-01")
            Issue.record("expected throw")
        } catch {
            #expect(CycleRepository.isCycleDisabled(error))
        }
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "a disabled-account read must not enqueue")
    }

    // MARK: - Outbox replay

    @Test("Outbox replay of a queued cycle day-log drains via bulk")
    func outboxReplayCycle() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        let write = CycleDayLogWrite(date: "2026-06-02", flow: .medium, loggedAt: "2026-06-02T08:00:00Z", externalId: "ext-r")
        let payload = try JSONEncoder.hlDefault.encode(OutboxQueue.Payloads.LogCycleDayLog(write: write))
        try await outbox.enqueue(.init(kind: .logCycleDayLog, payload: payload, idempotencyKey: "idem-cycle-1"))

        nonisolated(unsafe) var hitBulk = false
        nonisolated(unsafe) var replayIdem: String?
        MockURLProtocol.handler = { req in
            hitBulk = req.url?.path.hasSuffix("/api/cycle/day-logs/bulk") ?? false
            replayIdem = req.value(forHTTPHeaderField: "Idempotency-Key")
            let body = Data(#"{"data":{"entries":[{"index":0,"status":"inserted","id":"s","externalId":"ext-r"}]}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let api = makeAPI()
        let cycleRepo = CycleRepository(api: api, outbox: outbox)
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            cycleRepo: cycleRepo,
            currentUserProvider: { nil }
        )
        await replay.runOnce()
        #expect(hitBulk, "cycle day-log replay must drain through the bulk endpoint")
        #expect(replayIdem == "idem-cycle-1", "replay reuses the persisted idempotency key")
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "successful replay removes the op")
    }

    // MARK: - Sync tombstone identity

    @Test("Sync tombstone identity — cycleDays on externalId, cycles on id")
    func syncTombstoneIdentity() {
        #expect(SyncEntityKind.cycleDays.tombstoneKeysOnExternalId)
        #expect(!SyncEntityKind.cycles.tombstoneKeysOnExternalId)
        #expect(SyncEntityKind.cycleDays.urlSegment == "cycle/day-logs")
        #expect(SyncEntityKind.cycles.urlSegment == "cycle/cycles")
    }

    @Test("Cursor version bump → re-init on mismatch")
    func cursorVersionReinit() {
        #expect(SyncCursorVersion.current == 2)
        #expect(SyncCursorVersion.requiresReinit(persisted: 1))
        #expect(SyncCursorVersion.requiresReinit(persisted: nil))
        #expect(!SyncCursorVersion.requiresReinit(persisted: 2))
    }

    @Test("SyncState round-trips cycle high-water-marks")
    func syncStateCycleHWM() throws {
        let json = Data(#"{"cycleDays":"2026-06-01T10:00:00.000Z","cycles":"2026-05-30T09:00:00.000Z"}"#.utf8)
        let state = try JSONDecoder.hlDefault.decode(SyncState.self, from: json)
        #expect(state.highWaterMark(for: .cycleDays) != nil)
        #expect(state.highWaterMark(for: .cycles) != nil)
        #expect(state.highWaterMark(for: .measurement) == nil)
    }

    // MARK: - Hard purge (server v1.16, DELETE /api/cycle/all)

    @Test("purgeAll DELETEs /api/cycle/all and decodes the counts")
    func purgeAllWireShape() async throws {
        let repo = try CycleRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let body = Data(
                #"{"data":{"purged":true,"dayLogs":12,"customSymptoms":2,"predictions":3,"cycles":4,"auditRows":9,"pushRows":1},"error":null}"#
                    .utf8
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let result = try await repo.purgeAll()
        #expect(capturedPath == "/api/cycle/all")
        #expect(capturedMethod == "DELETE")
        #expect(result.purged)
        #expect(result.dayLogs == 12)
        #expect(result.cycles == 4)
    }

    @Test("purgeAll surfaces 403 cycle.disabled as the typed disabled error")
    func purgeAllDisabled() async throws {
        let repo = try CycleRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"cycle.disabled","errorCode":"cycle.disabled"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        do {
            _ = try await repo.purgeAll()
            Issue.record("expected 403 to throw")
        } catch {
            #expect(CycleRepository.isCycleDisabled(error))
        }
    }
}

// MARK: - v1.16.15 — temperatureExcluded + cervix + secondarySymptom

//
// Split into an extension (same file, so the private `makeAPI()` helper stays
// reachable) to keep the host struct body within `type_body_length`.

extension CycleDataLayerTests {
    @Test("v1.16.15 — day-log decodes temperatureExcluded + cervix fields (tolerant default)")
    func decodeDayLogV11615Fields() throws {
        let full = Data(#"""
        {"id":"d2","date":"2026-06-10","cycleId":null,"flow":null,
         "intermenstrualBleeding":false,"basalBodyTempC":36.7,"temperatureExcluded":true,
         "ovulationTest":null,"cervicalMucus":null,
         "cervixPosition":"HIGH","cervixFirmness":"SOFT","cervixOpening":"OPEN",
         "sexualActivity":false,"protectedSex":null,"pregnancyTest":null,
         "progesteroneTest":null,"contraceptive":null,"symptoms":[],"note":null,
         "source":"MANUAL","externalId":"e2","syncVersion":1,
         "updatedAt":"2026-06-10T08:00:00.000Z","deletedAt":null}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(CycleDayLogDTO.self, from: full)
        #expect(dto.temperatureExcluded == true)
        #expect(dto.cervixPositionValue == .high)
        #expect(dto.cervixFirmnessValue == .soft)
        #expect(dto.cervixOpeningValue == .open)

        // Older server omits the fields entirely → tolerant defaults (no cervix,
        // not excluded), the day-log still decodes exactly as before.
        let legacy = Data(#"""
        {"id":"d3","date":"2026-06-11","flow":"LIGHT","intermenstrualBleeding":false,
         "basalBodyTempC":36.5,"sexualActivity":false,"symptoms":[],"source":"MANUAL",
         "syncVersion":0,"updatedAt":null,"deletedAt":null}
        """#.utf8)
        let legacyDTO = try JSONDecoder.hlDefault.decode(CycleDayLogDTO.self, from: legacy)
        #expect(legacyDTO.temperatureExcluded == false)
        #expect(legacyDTO.cervixPositionValue == nil)
        #expect(legacyDTO.cervixFirmnessValue == nil)
        #expect(legacyDTO.cervixOpeningValue == nil)
    }

    @Test("v1.16.15 — calendar day decodes cervix + temperatureExcluded")
    func decodeCalendarDayV11615Fields() throws {
        let json = Data(#"""
        {"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,"cyclesObserved":4},
         "prediction":null,
         "days":[{"date":"2026-06-10","phase":"FOLLICULAR","isPredictedPeriod":false,
           "isFertileWindow":false,"isPredictedOvulation":false,"isPeriodLogged":false,
           "flow":null,"hasSymptoms":false,"confidence":0.6,"basalBodyTempC":36.7,
           "temperatureExcluded":true,"ovulationTest":null,"cervicalMucus":null,
           "cervixPosition":"LOW","cervixFirmness":"FIRM","cervixOpening":"CLOSED"}]}
        """#.utf8)
        let env = try JSONDecoder.hlDefault.decode(CycleCalendarResponse.self, from: json)
        let day = try #require(env.days.first)
        #expect(day.temperatureExcluded == true)
        #expect(day.cervixPositionValue == .low)
        #expect(day.cervixFirmnessValue == .firm)
        #expect(day.cervixOpeningValue == .closed)
    }

    @Test("v1.16.15 — structural still-learning: prediction nulls fertile/ovulation")
    func decodeStructuralStillLearning() throws {
        // Server with <3 cycles now nulls the fertile window + ovulation AND sets
        // stillLearning=true; the next-period estimate stays (honest).
        let json = Data(#"""
        {"method":"CALENDAR","nextPeriodStart":"2026-06-28","nextPeriodStartLow":"2026-06-26",
         "nextPeriodStartHigh":"2026-06-30","fertileWindowStart":null,"fertileWindowEnd":null,
         "predictedOvulation":null,"ovulationConfirmed":false,"confidence":0.3,
         "cyclesObserved":1,"stillLearning":true,"disclaimer":"Lernt noch"}
        """#.utf8)
        let p = try JSONDecoder.hlDefault.decode(CyclePredictionDTO.self, from: json)
        #expect(p.stillLearning)
        #expect(p.fertileWindowStart == nil)
        #expect(p.predictedOvulation == nil)
        #expect(!p.nextPeriodStart.isEmpty)
        // The maturity gate agrees: fertility suppressed (server authoritative).
        #expect(CycleMaturity.suppressFertility(cyclesObserved: p.cyclesObserved, stillLearning: p.stillLearning))
    }

    @Test("v1.16.15 — profile decodes secondarySymptom (CERVIX) + default")
    func decodeSecondarySymptom() throws {
        let cervix = Data(#"""
        {"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,
         "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,
         "typicalCycleLength":28,"secondarySymptom":"CERVIX","updatedAt":null}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(CycleProfileDTO.self, from: cervix)
        #expect(dto.secondarySymptomValue == .cervix)

        // Older server omits it → defaults to MUCUS.
        let legacy = Data(#"""
        {"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,
         "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,
         "updatedAt":null}
        """#.utf8)
        let legacyDTO = try JSONDecoder.hlDefault.decode(CycleProfileDTO.self, from: legacy)
        #expect(legacyDTO.secondarySymptomValue == .mucus)
    }

    @Test("v1.16.15 — CycleDayLogWrite encodes cervix + temperatureExcluded, omits when nil")
    func encodeV11615Write() throws {
        let with = CycleDayLogWrite(
            date: "2026-06-10",
            basalBodyTempC: 36.7,
            temperatureExcluded: true,
            cervixPosition: .high,
            cervixFirmness: .soft,
            cervixOpening: .open,
            loggedAt: "2026-06-10T08:00:00Z",
            externalId: "cycle-manual:2026-06-10"
        )
        let withJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any]
        )
        #expect(withJSON["temperatureExcluded"] as? Bool == true)
        #expect(withJSON["cervixPosition"] as? String == "HIGH")
        #expect(withJSON["cervixFirmness"] as? String == "SOFT")
        #expect(withJSON["cervixOpening"] as? String == "OPEN")

        // Unset → absent, never an explicit null (partial-PATCH guarantee).
        let without = CycleDayLogWrite(date: "2026-06-10", flow: .light, loggedAt: "2026-06-10T08:00:00Z")
        let withoutJSON = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(without)) as? [String: Any]
        )
        #expect(withoutJSON["temperatureExcluded"] == nil)
        #expect(withoutJSON["cervixPosition"] == nil)
        #expect(withoutJSON["cervixFirmness"] == nil)
        #expect(withoutJSON["cervixOpening"] == nil)
    }

    @Test("v1.16.15 — CyclePrefsPatch PATCHes secondarySymptom; store folds optimistically")
    func updateSecondarySymptomRequest() async throws {
        nonisolated(unsafe) var capturedBody: Data?
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedBody = req.bodyBytes()
            let body = Data(#"""
            {"data":{"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,
             "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,
             "secondarySymptom":"CERVIX","updatedAt":"2026-06-10T00:00:00.000Z"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try CycleRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let merged = try await repo.updatePrefs(CyclePrefsPatch(secondarySymptom: .cervix))
        #expect(merged.secondarySymptomValue == .cervix)
        #expect(capturedPath == "/api/auth/me/cycle-prefs")
        let json = try #require(capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["secondarySymptom"] as? String == "CERVIX")
        // Only the changed key rides the patch (partial PATCH).
        #expect(json["goal"] == nil)
    }
}

private extension URLRequest {
    /// Reads either `httpBody` or `httpBodyStream` (URLSession converts POST
    /// bodies to upload streams depending on session config).
    func bodyBytes() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
