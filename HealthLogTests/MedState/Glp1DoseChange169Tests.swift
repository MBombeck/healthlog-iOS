import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable file_length type_body_length force_unwrapping

// #169 (server 1.48.0) — titration steps go to the server once, under the
// local id as `clientId`; edit and remove go through PATCH / DELETE; a site is
// set on a recorded dose through the intake PUT, and a site the medication
// does not allow is explained once and never retried.

/// Answers each request through a closure and records every request.
private final class Glp1ScriptedAPI: APIClientProtocol, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let bodyData: Data?

        var body: [String: Any]? {
            bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private let lock = Mutex<[Call]>([])
    private let answer: @Sendable (Call) -> Result<String, HLError>

    init(_ answer: @escaping @Sendable (Call) -> Result<String, HLError>) {
        self.answer = answer
    }

    var calls: [Call] {
        lock.withLock { $0 }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let call = Call(method: request.method.rawValue, path: request.path, bodyData: request.body)
        lock.withLock { $0.append(call) }
        switch answer(call) {
        case let .success(json): return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
        case let .failure(error): throw error
        }
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = try await send(request)
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("not stubbed")
    }
}

private let medID = "med-1"
private let stepDate = Date(timeIntervalSince1970: 1_750_000_000)

private func makeLocalStore() throws -> GLP1LocalStore {
    try GLP1LocalStore(modelContainer: GLP1LocalStore.makeInMemory())
}

/// The `{ doseChange }` answer of create and edit.
private func doseChangeJSON(id: String, clientId: String?, dose: Double = 2.5, note: String? = nil) -> String {
    let client = clientId.map { "\"\($0)\"" } ?? "null"
    let noteValue = note.map { "\"\($0)\"" } ?? "null"
    return """
    {"doseChange":{"id":"\(id)","medicationId":"\(medID)","effectiveFrom":"2025-06-15T15:06:40.000Z",
    "doseValue":\(dose),"doseUnit":"mg","note":\(noteValue),"clientId":\(client),
    "createdAt":"2025-06-15T15:06:40.000Z"}}
    """
}

/// The intake PUT's answer.
private let intakeRowJSON = """
{"id":"i2","medicationId":"med-1","scheduledFor":"2025-06-15T15:00:00.000Z",
"takenAt":"2025-06-15T15:06:40.000Z","skipped":false}
"""

/// A switch the scripted answer reads.
private final class OnlineSwitch: Sendable {
    private let state = Mutex(false)
    var isOn: Bool {
        state.withLock { $0 }
    }

    func turnOn() {
        state.withLock { $0 = true }
    }
}

private func intake(_ id: String, takenAt: Date?, site: String? = nil, skipped: Bool = false) -> PaginatedIntakeEvent {
    PaginatedIntakeEvent(
        id: id,
        takenAt: takenAt,
        skipped: skipped,
        scheduledFor: takenAt ?? stepDate,
        injectionSite: site
    )
}

// MARK: - Titration upload

@Suite("#169 — titration steps upload once under their local id")
@MainActor
struct Glp1DoseChangeUploadTests {
    /// A local step as a 1.7 build wrote it: no upload marker.
    private func seedLegacyStep(_ local: GLP1LocalRepository, note: String? = "first week") async throws -> String {
        try await local.addTitrationStep(medicationID: medID, effectiveFrom: stepDate, doseMg: 2.5, note: note).id
    }

    @Test("the create carries the body and the local id as clientId, and the row is marked")
    func uploadBody() async throws {
        let api = Glp1ScriptedAPI { call in
            let clientId = (call.body?["doseChange"] as? [String: Any])?["clientId"] as? String
            return .success(doseChangeJSON(id: "srv-1", clientId: clientId))
        }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        let localID = try await seedLegacyStep(local)
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)

        await store.load(serverChanges: [])
        await store.settleUpload()

        let call = try #require(api.calls.first)
        #expect(api.calls.count == 1)
        #expect(call.method == "POST")
        #expect(call.path == "/api/medications/\(medID)/glp1")
        let body = try #require(call.body?["doseChange"] as? [String: Any])
        #expect(body["clientId"] as? String == localID)
        #expect(body["doseValue"] as? Double == 2.5)
        #expect(body["doseUnit"] as? String == "mg")
        #expect(body["note"] as? String == "first week")
        #expect(body["effectiveFrom"] is String)
        #expect(call.body?["inventory"] == nil, "the body carries exactly one arm")

        let marked = try await local.titrationSteps(medicationID: medID)
        #expect(marked.map(\.serverID) == ["srv-1"])
        #expect(store.mergedTimeline.map(\.id) == ["srv-1"], "the server's step replaces the local one")
        #expect(store.mergedTimeline.first?.source == .server)
    }

    @Test("update path: a 1.7 row goes up once, a second load sends nothing")
    func markerStopsSecondUpload() async throws {
        let api = Glp1ScriptedAPI { call in
            let clientId = (call.body?["doseChange"] as? [String: Any])?["clientId"] as? String
            return .success(doseChangeJSON(id: "srv-1", clientId: clientId))
        }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        let legacyID = try await seedLegacyStep(local)
        // A row a later build already uploaded.
        let uploaded = try await local.addTitrationStep(
            medicationID: medID,
            effectiveFrom: stepDate.addingTimeInterval(86400 * 30),
            doseMg: 5,
            note: nil
        )
        try await local.markTitrationStepUploaded(localID: uploaded.id, serverID: "srv-0")

        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)
        await store.load(serverChanges: [])
        await store.settleUpload()
        #expect(api.calls.count == 1)
        let sent = (api.calls.first?.body?["doseChange"] as? [String: Any])?["clientId"] as? String
        #expect(sent == legacyID, "only the unmarked row goes up")

        await store.load(serverChanges: [Glp1DoseChangeDTO(
            id: "srv-1",
            effectiveFrom: stepDate,
            doseValue: 2.5,
            doseUnit: "mg",
            clientId: legacyID
        )])
        await store.settleUpload()
        #expect(api.calls.count == 1, "a marked row is never sent again")
    }

    @Test("a 200 for a step the server already holds counts as done")
    func repeatCountsAsDone() async throws {
        // The answer to a repeat is the stored step, under the server's id.
        let api = Glp1ScriptedAPI { call in
            let clientId = (call.body?["doseChange"] as? [String: Any])?["clientId"] as? String
            return .success(doseChangeJSON(id: "srv-from-ipad", clientId: clientId))
        }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        _ = try await seedLegacyStep(local)
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)

        await store.load(serverChanges: [])
        await store.settleUpload()

        #expect(try await local.titrationSteps(medicationID: medID).map(\.serverID) == ["srv-from-ipad"])
        #expect(store.mergedTimeline.count == 1)
        #expect(store.error == nil)
    }

    @Test("a step the server already lists under the local id is marked without a request")
    func listedStepNeedsNoRequest() async throws {
        let api = Glp1ScriptedAPI { _ in .failure(.unknown("no request expected")) }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        let localID = try await seedLegacyStep(local)
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)

        await store.load(serverChanges: [
            Glp1DoseChangeDTO(id: "srv-9", effectiveFrom: stepDate, doseValue: 2.5, doseUnit: "mg", clientId: localID)
        ])
        await store.settleUpload()

        #expect(api.calls.isEmpty)
        #expect(try await local.titrationSteps(medicationID: medID).map(\.serverID) == ["srv-9"])
    }

    @Test("410 glp1.doseChange.deleted drops the local copy for good")
    func deletedDropsLocal() async throws {
        let api = Glp1ScriptedAPI { _ in
            .failure(.server(status: 410, code: "glp1.doseChange.deleted", message: "This dose step was removed"))
        }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        _ = try await seedLegacyStep(local)
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)

        await store.load(serverChanges: [])
        await store.settleUpload()

        #expect(try await local.titrationSteps(medicationID: medID).isEmpty)
        #expect(store.mergedTimeline.isEmpty)
        await store.load(serverChanges: [])
        await store.settleUpload()
        #expect(api.calls.count == 1, "nothing is left to send again")
    }

    @Test("offline keeps the row waiting and sends it on the next load")
    func offlineKeepsPending() async throws {
        let online = OnlineSwitch()
        let api = Glp1ScriptedAPI { call in
            guard online.isOn else { return .failure(.offline) }
            let clientId = (call.body?["doseChange"] as? [String: Any])?["clientId"] as? String
            return .success(doseChangeJSON(id: "srv-1", clientId: clientId))
        }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        _ = try await seedLegacyStep(local)
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)

        await store.load(serverChanges: [])
        await store.settleUpload()
        #expect(try await local.titrationSteps(medicationID: medID).map(\.serverID) == [nil])
        #expect(store.mergedTimeline.first?.source == .local)
        #expect(store.error == nil, "a waiting upload is no failure")

        online.turnOn()
        await store.load(serverChanges: [])
        await store.settleUpload()
        #expect(try await local.titrationSteps(medicationID: medID).map(\.serverID) == ["srv-1"])
    }

    @Test("a new step goes up right after it is saved")
    func addUploads() async throws {
        let api = Glp1ScriptedAPI { call in
            let clientId = (call.body?["doseChange"] as? [String: Any])?["clientId"] as? String
            return .success(doseChangeJSON(id: "srv-new", clientId: clientId, dose: 5))
        }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)
        await store.load(serverChanges: [])
        await store.settleUpload()

        let failure = await store.add(effectiveFrom: stepDate, doseMg: 5, note: nil)
        await store.settleUpload()

        #expect(failure == nil)
        #expect(api.calls.count == 1)
        let body = try #require(api.calls.first?.body?["doseChange"] as? [String: Any])
        #expect(body.keys.contains("note") == false, "a missing note is left out")
        #expect(store.mergedTimeline.map(\.id) == ["srv-new"])
    }
}

// MARK: - Edit and remove

@Suite("#169 — a server step is edited with PATCH and removed with DELETE")
@MainActor
struct Glp1DoseChangeEditTests {
    private let serverStep = Glp1DoseChangeDTO(id: "srv-1", effectiveFrom: stepDate, doseValue: 2.5, doseUnit: "mg", note: "old")

    @Test("edit goes to PATCH …/glp1/dose-changes/{id}; a cleared note is sent as null")
    func patchPath() async throws {
        let api = Glp1ScriptedAPI { _ in .success(doseChangeJSON(id: "srv-1", clientId: nil, dose: 5)) }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)
        await store.load(serverChanges: [serverStep])
        await store.settleUpload()
        #expect(store.canEditServerSteps)

        let failure = await store.update(id: "srv-1", effectiveFrom: stepDate, doseMg: 5, note: nil)

        #expect(failure == nil)
        let call = try #require(api.calls.first)
        #expect(call.method == "PATCH")
        #expect(call.path == "/api/medications/\(medID)/glp1/dose-changes/srv-1")
        let body = try #require(call.body)
        #expect(body["doseValue"] as? Double == 5)
        #expect(body["doseUnit"] as? String == "mg")
        #expect(body["note"] is NSNull)
        #expect(body["clientId"] == nil, "the client id is never edited")
        #expect(store.mergedTimeline.first?.doseMg == 5)
    }

    @Test("remove goes to DELETE …/glp1/dose-changes/{id} and drops the local mirror")
    func deletePath() async throws {
        let api = Glp1ScriptedAPI { _ in .success(#"{"id":"srv-1","deleted":true}"#) }
        let local = try GLP1LocalRepository(store: makeLocalStore(), doseChangeServer: Glp1DoseChangeRepository(api: api))
        let mirror = try await local.addTitrationStep(medicationID: medID, effectiveFrom: stepDate, doseMg: 2.5, note: nil)
        try await local.markTitrationStepUploaded(localID: mirror.id, serverID: "srv-1")
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)
        await store.load(serverChanges: [serverStep])
        await store.settleUpload()

        let removed = await store.delete(id: "srv-1")

        #expect(removed)
        let call = try #require(api.calls.first)
        #expect(call.method == "DELETE")
        #expect(call.path == "/api/medications/\(medID)/glp1/dose-changes/srv-1")
        #expect(store.mergedTimeline.isEmpty)
        #expect(try await local.titrationSteps(medicationID: medID).isEmpty)
    }

    @Test("a step already gone (404) counts as removed")
    func deleteOfMissingStep() async throws {
        let api = Glp1ScriptedAPI { _ in .failure(.server(status: 404, code: nil, message: "Dose change not found")) }
        let repo = Glp1DoseChangeRepository(api: api)
        try await repo.delete(medicationID: medID, doseChangeID: "srv-gone")
    }

    @Test("without a server seam a server step stays read-only")
    func noSeamReadOnly() async throws {
        let local = try GLP1LocalRepository(store: makeLocalStore())
        let store = TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: local)
        await store.load(serverChanges: [serverStep])
        await store.settleUpload()
        #expect(!store.canEditServerSteps)
    }
}

// MARK: - Upload plan (pure)

@Suite("#169 — upload plan")
struct Glp1DoseChangeUploadPlanTests {
    private func step(
        id: String = UUID().uuidString,
        at date: Date = stepDate,
        dose: Double = 2.5,
        note: String? = nil,
        serverID: String? = nil
    ) -> TitrationStepEntrySnapshot {
        TitrationStepEntrySnapshot(
            id: id, medicationID: medID, effectiveFrom: date, doseMg: dose, note: note, createdAt: date, serverID: serverID
        )
    }

    @Test("pending: unmarked and uploadable rows, oldest first")
    func pending() {
        let late = step(id: "b", at: stepDate.addingTimeInterval(86400))
        let early = step(id: "a")
        let marked = step(id: "c", serverID: "srv")
        let tooOld = step(id: "d", at: Date(timeIntervalSince1970: 1_500_000_000))
        let badId = step(id: "has space")
        let plan = Glp1DoseChangeUploadPlan.pending([late, marked, early, tooOld, badId], now: stepDate)
        #expect(plan.map(\.id) == ["a", "b"])
    }

    @Test("body: local id as clientId, mg, note capped at the server's 500")
    func body() {
        let row = step(id: "local-1", note: String(repeating: "x", count: 512))
        let body = Glp1DoseChangeUploadPlan.body(for: row)
        #expect(body.clientId == "local-1")
        #expect(body.doseUnit == "mg")
        #expect(body.doseValue == 2.5)
        #expect(body.note?.count == 500)
    }

    @Test("resolve: success marks, 410 drops, anything else waits")
    func resolve() {
        let stored = Glp1DoseChangeDTO(id: "srv-1", effectiveFrom: stepDate, doseValue: 2.5, doseUnit: "mg")
        #expect(Glp1DoseChangeUploadPlan.resolve(.success(stored)) == .markUploaded(serverID: "srv-1"))
        let gone = HLError.server(status: 410, code: "glp1.doseChange.deleted", message: "")
        #expect(Glp1DoseChangeUploadPlan.resolve(.failure(gone)) == .dropLocal)
        #expect(Glp1DoseChangeUploadPlan.resolve(.failure(HLError.offline)) == .keepPending)
        let otherGone = HLError.server(status: 410, code: nil, message: "")
        #expect(Glp1DoseChangeUploadPlan.resolve(.failure(otherGone)) == .keepPending)
    }

    @Test("a UUID string is a valid client id")
    func uuidIsValidClientId() {
        #expect(Glp1DoseChangeUploadPlan.isValidClientId(UUID().uuidString))
        #expect(!Glp1DoseChangeUploadPlan.isValidClientId(""))
        #expect(!Glp1DoseChangeUploadPlan.isValidClientId(String(repeating: "a", count: 129)))
    }

    @Test("the list GET decodes clientId, and an older server without it")
    func dtoDecodesClientId() throws {
        let json = #"[{"id":"s1","effectiveFrom":"2025-06-15T15:06:40.000Z","doseValue":2.5,"doseUnit":"mg","note":null,"clientId":"abc"},"#
            + #"{"id":"s2","effectiveFrom":"2025-06-16T15:06:40.000Z","doseValue":5,"doseUnit":"mg"}]"#
        let rows = try JSONDecoder.hlDefault.decode([Glp1DoseChangeDTO].self, from: Data(json.utf8))
        #expect(rows.map(\.clientId) == ["abc", nil])
    }
}

// MARK: - Intake PUT with injectionSite

@Suite("#169 — the intake PUT carries injectionSite: set, null, absent")
struct IntakePatchInjectionSiteTests {
    private func object(_ patch: MedicationsRepository.IntakePatch) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(patch)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("set sends the server's enum string")
    func set() throws {
        let body = try object(Glp1DoseChangeRepository.sitePatch(.abdomenLeftLower))
        #expect(body["injectionSite"] as? String == "ABDOMEN_LEFT")
        #expect(body.count == 1, "nothing else is touched")
    }

    @Test("null clears")
    func clear() throws {
        let body = try object(Glp1DoseChangeRepository.sitePatch(nil))
        #expect(body["injectionSite"] is NSNull)
    }

    @Test("absent keeps: an ordinary edit carries no injectionSite key")
    func absent() throws {
        let body = try object(MedicationsRepository.IntakePatch(skipped: false))
        #expect(body.keys.contains("injectionSite") == false)
    }

    @Test("a site this build cannot name is never written")
    func unknownSiteRefused() {
        #expect(throws: HLError.self) { try Glp1DoseChangeRepository.sitePatch(.unknown) }
    }

    @Test("the outbox payload round-trips all three states")
    func roundTrip() throws {
        for field: MedicationsRepository.PatchField<String> in [.absent, .null, .value("UPPER_ARM_LEFT")] {
            let patch = MedicationsRepository.IntakePatch(injectionSite: field)
            let data = try JSONEncoder.hlDefault.encode(patch)
            let decoded = try JSONDecoder.hlDefault.decode(MedicationsRepository.IntakePatch.self, from: data)
            #expect(decoded == patch)
        }
    }
}

// MARK: - Site on the last injection

@Suite("#169 — a site is set on the last injection; a disallowed one is explained, not retried")
@MainActor
struct InjectionSiteOnDoseTests {
    private func makeStore(api: Glp1ScriptedAPI, outbox: OutboxQueue) throws -> (InjectionSiteStore, GLP1LocalRepository) {
        let medications = MedicationsRepository(api: api, outbox: outbox)
        let local = try GLP1LocalRepository(
            store: makeLocalStore(),
            doseChangeServer: Glp1DoseChangeRepository(api: api, medications: medications)
        )
        return (InjectionSiteStore(medicationID: medID, repo: local), local)
    }

    private let intakes = [
        intake("i1", takenAt: stepDate.addingTimeInterval(-7 * 86400), site: "THIGH_LEFT"),
        intake("i2", takenAt: stepDate)
    ]

    @Test("the PUT goes to the last injection and the site shows")
    func setOnLast() async throws {
        let api = Glp1ScriptedAPI { _ in .success(intakeRowJSON) }
        let outbox = try OutboxQueue(inMemory: true)
        let (store, _) = try makeStore(api: api, outbox: outbox)
        await store.load(serverIntakes: intakes)
        #expect(store.lastInjection?.id == "i2")
        #expect(store.canSetSite)

        let written = await store.setSiteOnLastInjection(.armLeft)

        #expect(written)
        let call = try #require(api.calls.first)
        #expect(call.method == "PUT")
        #expect(call.path == "/api/medications/\(medID)/intake/i2")
        #expect(call.body?["injectionSite"] as? String == "UPPER_ARM_LEFT")
        #expect(store.lastInjectionSite == .armLeft)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("422 injection_site.disallowed: one sentence, no outbox row, no second request")
    func disallowedNotRetried() async throws {
        let api = Glp1ScriptedAPI { _ in
            .failure(.server(status: 422, code: "medications.intake.injection_site.disallowed", message: "Injection site not allowed"))
        }
        let outbox = try OutboxQueue(inMemory: true)
        let (store, _) = try makeStore(api: api, outbox: outbox)
        await store.load(serverIntakes: intakes)

        let written = await store.setSiteOnLastInjection(.armLeft)

        #expect(!written)
        #expect(store.notice == InjectionSiteStore.disallowedSentence)
        #expect(store.error == nil, "the sentence replaces the banner")
        #expect(await outbox.snapshot.isEmpty, "a refused site is not queued")
        #expect(api.calls.count == 1)
        #expect(store.lastInjectionSite == nil)
    }

    @Test("offline: the site waits in the outbox like every intake edit")
    func offlineQueued() async throws {
        let api = Glp1ScriptedAPI { _ in .failure(.offline) }
        let outbox = try OutboxQueue(inMemory: true)
        let (store, _) = try makeStore(api: api, outbox: outbox)
        await store.load(serverIntakes: intakes)

        let written = await store.setSiteOnLastInjection(.armLeft)

        #expect(written)
        #expect(await outbox.snapshot.count == 1)
    }

    @Test("a device-only site is offered for its dose and goes up on confirm")
    func offerApplied() async throws {
        let api = Glp1ScriptedAPI { _ in .success(intakeRowJSON) }
        let outbox = try OutboxQueue(inMemory: true)
        let (store, local) = try makeStore(api: api, outbox: outbox)
        // Logged on the device by an older build, half an hour after the dose.
        _ = try await local.addSite(medicationID: medID, injectedAt: stepDate.addingTimeInterval(1800), site: .abdomenRightLower, note: nil)
        await store.load(serverIntakes: intakes)
        #expect(api.calls.isEmpty, "nothing goes up before the person confirms")

        let offer = try #require(store.offers.first)
        #expect(offer.intakeID == "i2")
        let applied = await store.apply(offer)

        #expect(applied)
        #expect(api.calls.first?.body?["injectionSite"] as? String == "ABDOMEN_RIGHT")
        #expect(try await local.sites(medicationID: medID).isEmpty, "the device copy goes once the server has it")
        #expect(store.offers.isEmpty)
    }
}

// MARK: - Matcher (pure)

@Suite("#169 — matching a device-only site to its dose")
struct InjectionSiteOfferMatcherTests {
    private func site(_ id: String, _ site: InjectionSite, at date: Date, med: String = medID) -> InjectionSiteEntrySnapshot {
        InjectionSiteEntrySnapshot(id: id, medicationID: med, injectedAt: date, siteRaw: site.rawValue, note: nil, createdAt: date)
    }

    @Test("same medication, within a few hours, dose without a site")
    func matches() {
        let offers = InjectionSiteOfferMatcher.offers(
            medicationID: medID,
            localSites: [site("l1", .armLeft, at: stepDate.addingTimeInterval(3600))],
            intakes: [intake("i1", takenAt: stepDate)]
        )
        #expect(offers.map(\.intakeID) == ["i1"])
        #expect(offers.first?.site == .armLeft)
    }

    @Test("no offer: other medication, too far apart, dose has a site, skipped or untaken dose")
    func noMatch() {
        let offers = InjectionSiteOfferMatcher.offers(
            medicationID: medID,
            localSites: [
                site("other-med", .armLeft, at: stepDate, med: "med-2"),
                site("far", .armLeft, at: stepDate.addingTimeInterval(-10 * 3600))
            ],
            intakes: [
                intake("has-site", takenAt: stepDate, site: "ARM_RIGHT"),
                intake("skipped", takenAt: stepDate, skipped: true),
                intake("untaken", takenAt: nil)
            ]
        )
        #expect(offers.isEmpty)
    }

    @Test("one site per dose and one dose per site, the closest pair wins")
    func oneToOne() {
        let offers = InjectionSiteOfferMatcher.offers(
            medicationID: medID,
            localSites: [
                site("near", .armLeft, at: stepDate.addingTimeInterval(600)),
                site("further", .armRight, at: stepDate.addingTimeInterval(7200))
            ],
            intakes: [intake("i1", takenAt: stepDate)]
        )
        #expect(offers.count == 1)
        #expect(offers.first?.localID == "near")
    }

    @Test("the window edge is inclusive and a site this build cannot name is never offered")
    func edges() {
        let window = InjectionSiteOfferMatcher.window
        let offers = InjectionSiteOfferMatcher.offers(
            medicationID: medID,
            localSites: [
                site("edge", .thighLeft, at: stepDate.addingTimeInterval(window)),
                InjectionSiteEntrySnapshot(
                    id: "unknown", medicationID: medID, injectedAt: stepDate, siteRaw: "nowhere", note: nil, createdAt: stepDate
                )
            ],
            intakes: [intake("i1", takenAt: stepDate)]
        )
        #expect(offers.map(\.localID) == ["edge"])
    }
}
