import Foundation
@testable import HealthLog
import Testing

/// Lab results from Health Records (#180, contract #182 part A §3).
@Suite("Health Records labs: gate, batching, answers, cursor")
struct ClinicalLabRecordSyncTests {
    // MARK: - Fixtures

    static func defaults(server: String? = "1.48.0") -> UserDefaults {
        let name = "ClinicalLabRecordSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        if let server { defaults.set(server, forKey: KnownServerVersion.defaultsKey) }
        return defaults
    }

    static func record(_ index: Int, bytes: Int = 0) -> ClinicalLabRecord {
        let padding = String(repeating: "x", count: bytes)
        let json = #"{"resourceType":"Observation","id":"obs-\#(index)","note":"\#(padding)"}"#
        return ClinicalLabRecord(
            sampleID: UUID(),
            resource: Data(json.utf8),
            fhirVersion: "4.0.1",
            identifier: "obs-\(index)",
            sourceURL: "https://fhir.example.org/r4/",
            sourceName: "Example Clinic"
        )
    }

    static func response(_ statuses: [(String, String?)]) -> ClinicalLabBatchResponse {
        ClinicalLabBatchResponse(
            results: statuses.enumerated().map { .init(index: $0.offset, status: $0.element.0, reason: $0.element.1) },
            inserted: nil, duplicate: nil, skipped: nil, failed: nil
        )
    }

    // MARK: - Gate

    @Test("the offer needs Apple Health, Health Records and server 1.48.0")
    func gate() {
        #expect(ClinicalLabRecordsGate.isAvailable(readsHealthKit: true, supportsHealthRecords: true, defaults: Self.defaults()))
        #expect(ClinicalLabRecordsGate.isAvailable(
            readsHealthKit: true,
            supportsHealthRecords: true,
            defaults: Self.defaults(server: "1.49.2")
        ))
        #expect(!ClinicalLabRecordsGate.isAvailable(
            readsHealthKit: true,
            supportsHealthRecords: true,
            defaults: Self.defaults(server: "1.47.9")
        ))
        #expect(!ClinicalLabRecordsGate.isAvailable(
            readsHealthKit: true,
            supportsHealthRecords: true,
            defaults: Self.defaults(server: nil)
        ))
        #expect(!ClinicalLabRecordsGate.isAvailable(readsHealthKit: true, supportsHealthRecords: false, defaults: Self.defaults()))
        #expect(!ClinicalLabRecordsGate.isAvailable(readsHealthKit: false, supportsHealthRecords: true, defaults: Self.defaults()))
    }

    @Test("the diagnostics row names each state")
    func diagnosticsStatus() {
        let open = Self.defaults()
        #expect(ClinicalLabRecordsStatus.current(readsHealthKit: true, supportsHealthRecords: false, defaults: open) == .notOnThisSystem)
        #expect(ClinicalLabRecordsStatus.current(
            readsHealthKit: true,
            supportsHealthRecords: true,
            defaults: Self.defaults(server: "1.47.0")
        )
            == .waitingForServer)
        #expect(ClinicalLabRecordsStatus.current(readsHealthKit: true, supportsHealthRecords: true, defaults: open) == .notConnected)
        ClinicalLabRecordsConsent.record(.requested, defaults: open)
        #expect(ClinicalLabRecordsStatus.current(readsHealthKit: true, supportsHealthRecords: true, defaults: open) == .active)
    }

    // MARK: - Consent

    @Test("a declined offer never comes back and never syncs")
    func declineIsFinal() {
        let defaults = Self.defaults()
        #expect(ClinicalLabRecordsConsent.offersCard(isAvailable: true, defaults: defaults))
        ClinicalLabRecordsConsent.record(.declined, defaults: defaults)
        #expect(!ClinicalLabRecordsConsent.offersCard(isAvailable: true, defaults: defaults))
        #expect(!ClinicalLabRecordsConsent.syncs(isAvailable: true, defaults: defaults))
    }

    @MainActor
    @Test("declining in Labs records the answer and asks HealthKit nothing")
    func storeDecline() async {
        let defaults = Self.defaults()
        let reader = ClinicalLabFakeReader(records: [])
        let store = ClinicalLabRecordsStore(
            importer: Self.importer(reader: reader, defaults: defaults),
            readsHealthKit: true,
            defaults: defaults
        )
        #expect(store.offersCard)
        store.decline()
        #expect(!store.offersCard)
        #expect(ClinicalLabRecordsStore(importer: nil, readsHealthKit: true, defaults: defaults).consent == .declined)
        #expect(await reader.authorizationRequests == 0)
    }

    @MainActor
    @Test("connecting asks once, then the offer is gone and the first sync runs")
    func storeConnect() async {
        let defaults = Self.defaults()
        let reader = ClinicalLabFakeReader(records: [Self.record(1)])
        let uploader = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("inserted", nil) }) }
        let store = ClinicalLabRecordsStore(
            importer: Self.importer(reader: reader, uploader: uploader, defaults: defaults),
            readsHealthKit: true,
            defaults: defaults
        )
        await store.connect()
        #expect(await reader.authorizationRequests == 1)
        #expect(store.consent == .requested)
        #expect(!store.offersCard)
        #expect(await uploader.calls.count == 1)
        await store.connect()
        #expect(await reader.authorizationRequests == 1)
    }

    @MainActor
    @Test("no offer on an old server, without Health Records, or without Apple Health")
    func storeGateOff() {
        let old = Self.defaults(server: "1.47.3")
        #expect(!ClinicalLabRecordsStore(
            importer: Self.importer(reader: ClinicalLabFakeReader(records: []), defaults: old),
            readsHealthKit: true,
            defaults: old
        )
        .offersCard)
        let open = Self.defaults()
        #expect(!ClinicalLabRecordsStore(
            importer: Self.importer(reader: ClinicalLabFakeReader(records: [], supports: false), defaults: open),
            readsHealthKit: true,
            defaults: open
        ).offersCard)
        #expect(!ClinicalLabRecordsStore(importer: nil, readsHealthKit: false, defaults: open).offersCard)
    }

    // MARK: - Batching and body

    @Test("records go out in calls of at most 200")
    func batchesOf200() {
        let records = (0 ..< 450).map { Self.record($0) }
        let split = ClinicalLabRecordBatching.batches(records)
        #expect(split.batches.map(\.count) == [200, 200, 50])
        #expect(split.leftOut.isEmpty)
        #expect(split.batches.flatMap(\.self).map(\.sampleID) == records.map(\.sampleID))
        #expect(ClinicalLabRecordBatching.batches([]).batches.isEmpty)
    }

    @Test("oversized or unreadable resources stay home, large ones split the call")
    func oversizedAndBodyBudget() {
        let huge = Self.record(1, bytes: ClinicalLabRecordBatching.maxResourceBytes + 1)
        let broken = ClinicalLabRecord(
            sampleID: UUID(),
            resource: Data("[1,2]".utf8),
            fhirVersion: nil,
            identifier: nil,
            sourceURL: nil,
            sourceName: nil
        )
        let big = (0 ..< 12).map { Self.record($0, bytes: 200 * 1024) }
        let split = ClinicalLabRecordBatching.batches([huge, broken] + big)
        #expect(split.leftOut.map(\.sampleID) == [huge.sampleID, broken.sampleID])
        #expect(split.batches.flatMap(\.self).count == 12)
        for batch in split.batches {
            // The whole encoded body, envelope included, stays under the server's 1 MiB.
            let body = (try? ClinicalLabRecordBatching.body(for: batch)) ?? Data()
            #expect(body.count <= ClinicalLabRecordBatching.maxBodyBytes)
            #expect(body.count < 1024 * 1024)
        }
        #expect(ClinicalLabRecordBatching.maxBodyBytes < 1024 * 1024)
    }

    @Test("a body full of escaped characters is counted as sent, not as read")
    func escapedBodyStaysUnderTheLimit() throws {
        // Every "/" becomes "\/" on the wire: 160 KiB of slashes encode to 320 KiB.
        let slashes = (0 ..< 6).map { index in
            ClinicalLabRecord(
                sampleID: UUID(),
                resource: Data(#"{"resourceType":"Observation","id":"s\#(index)","note":"\#(String(repeating: "/", count: 160 * 1024))"}"#
                    .utf8),
                fhirVersion: "4.0.1",
                identifier: nil,
                sourceURL: nil,
                sourceName: nil
            )
        }
        let split = ClinicalLabRecordBatching.batches(slashes)
        #expect(split.batches.count > 1)
        for batch in split.batches {
            #expect(try ClinicalLabRecordBatching.body(for: batch).count <= ClinicalLabRecordBatching.maxBodyBytes)
        }
    }

    @Test("the body carries the resource as an object with its source fields")
    func body() throws {
        var record = Self.record(7)
        record = ClinicalLabRecord(
            sampleID: record.sampleID,
            resource: record.resource,
            fhirVersion: "4.0.1",
            identifier: String(repeating: "i", count: 257),
            sourceURL: "https://fhir.example.org/r4/",
            sourceName: String(repeating: "n", count: 250)
        )
        let data = try ClinicalLabRecordBatching.body(for: [record])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(json["records"] as? [[String: Any]])
        #expect(records.count == 1)
        let entry = records[0]
        let resource = try #require(entry["resource"] as? [String: Any])
        #expect(resource["resourceType"] as? String == "Observation")
        #expect(entry["fhirVersion"] as? String == "4.0.1")
        #expect(entry["identifier"] == nil, "an identifier over 256 is left out, not cut")
        #expect(entry["sourceURL"] as? String == "https://fhir.example.org/r4/")
        #expect((entry["sourceName"] as? String)?.count == 200)
    }

    // MARK: - Answers

    @Test("each status: only write_failed and missing answers go out again")
    func classify() {
        let batch = (0 ..< 6).map { Self.record($0) }
        let response = Self.response([
            ("inserted", nil), ("duplicate", nil), ("skipped", "not_lab"),
            ("failed", "missing_unit"), ("failed", "write_failed")
        ])
        let outcome = ClinicalLabBatchOutcome.classify(response, batch: batch)
        #expect(outcome.inserted == 1)
        #expect(outcome.duplicate == 1)
        #expect(outcome.skipped == 1)
        #expect(outcome.failed == 1)
        #expect(outcome.resend == [batch[4].sampleID, batch[5].sampleID])
    }

    @Test("a refused body moves on, everything else holds")
    func callFailures() {
        #expect(ClinicalLabCallFailure.of(HLError.server(status: 422, code: "labs.fhir_batch.invalid", message: "x")) == .refused)
        #expect(ClinicalLabCallFailure.of(HLError.server(status: 500, code: nil, message: "x")) == .hold)
        #expect(ClinicalLabCallFailure.of(HLError.server(status: 404, code: nil, message: "x")) == .hold)
        #expect(ClinicalLabCallFailure.of(HLError.rateLimited(retryAfter: 30)) == .hold)
        #expect(ClinicalLabCallFailure.of(HLError.offline) == .hold)
        #expect(ClinicalLabCallFailure.of(HLError.unauthorized) == .hold)
    }

    // MARK: - Importer

    @Test("a pass sends 250 records in two calls and keeps the anchor")
    func passSendsPagesAndCommits() async {
        let defaults = Self.defaults()
        ClinicalLabRecordsConsent.record(.requested, defaults: defaults)
        let reader = ClinicalLabFakeReader(records: (0 ..< 250).map { Self.record($0) })
        let uploader = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("inserted", nil) }) }
        let importer = Self.importer(reader: reader, uploader: uploader, defaults: defaults)
        guard case let .completed(outcome) = await importer.sync() else {
            Issue.record("the pass did not complete")
            return
        }
        #expect(outcome.inserted == 250)
        #expect(await uploader.calls.map(\.count) == [200, 50])
        // Nothing new: the next pass sends nothing.
        #expect(await importer.sync() == .completed(ClinicalLabBatchOutcome()))
        #expect(await uploader.calls.count == 2)
        let cursor = ClinicalLabRecordCursorStore(defaults: defaults).load(owner: "owner-a")
        #expect(cursor.totalInserted == 250)
        #expect(cursor.lastPass != nil)
    }

    @Test("write_failed is sent again on the next pass, duplicate is done")
    func resendOnlyWriteFailed() async {
        let defaults = Self.defaults()
        ClinicalLabRecordsConsent.record(.requested, defaults: defaults)
        let records = (0 ..< 3).map { Self.record($0) }
        let reader = ClinicalLabFakeReader(records: records)
        let uploader = ClinicalLabFakeUploader { batch in
            Self.response(batch.map { $0.identifier == "obs-1" ? ("failed", "write_failed") : ("duplicate", nil) })
        }
        let importer = Self.importer(reader: reader, uploader: uploader, defaults: defaults)
        _ = await importer.sync()
        #expect(ClinicalLabRecordCursorStore(defaults: defaults).load(owner: "owner-a").resend == [records[1].sampleID])
        _ = await importer.sync()
        let calls = await uploader.calls
        #expect(calls.count == 2)
        #expect(calls[1].map(\.identifier) == ["obs-1"])
    }

    @Test("a call without an answer holds the anchor; the next pass sends the page again")
    func transportFailureHolds() async {
        let defaults = Self.defaults()
        ClinicalLabRecordsConsent.record(.requested, defaults: defaults)
        let reader = ClinicalLabFakeReader(records: (0 ..< 3).map { Self.record($0) })
        let failing = ClinicalLabFakeUploader { _ in throw HLError.offline }
        let held = await Self.importer(reader: reader, uploader: failing, defaults: defaults).sync()
        guard case .held = held else {
            Issue.record("the pass did not hold")
            return
        }
        #expect(held.capabilityResult(.clinicalLabRecords).disposition == .deferred)
        #expect(ClinicalLabRecordCursorStore(defaults: defaults).load(owner: "owner-a").anchor == nil)
        let working = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("inserted", nil) }) }
        _ = await Self.importer(reader: reader, uploader: working, defaults: defaults).sync()
        #expect(await working.calls.map(\.count) == [3])
    }

    @Test("clearing one account's cursor leaves the other's")
    func cursorClearIsPerAccount() {
        let store = ClinicalLabRecordCursorStore(defaults: Self.defaults())
        var cursor = ClinicalLabRecordCursor()
        cursor.anchor = Data([1])
        store.save(cursor, owner: "owner-a")
        store.save(cursor, owner: "owner-b")
        store.clear(owner: "owner-a")
        #expect(store.load(owner: "owner-a").anchor == nil)
        #expect(store.load(owner: "owner-b").anchor == Data([1]))
    }

    @Test("cursors are kept per account")
    func cursorPerAccount() {
        let store = ClinicalLabRecordCursorStore(defaults: Self.defaults())
        var cursor = ClinicalLabRecordCursor()
        cursor.anchor = Data([1])
        store.save(cursor, owner: "owner-a")
        #expect(store.load(owner: "owner-a").anchor == Data([1]))
        #expect(store.load(owner: "owner-b").anchor == nil)
        #expect(!ClinicalLabRecordCursorStore.key(owner: "owner-a").contains("owner-a"))
    }

    @Test("the capability is an opt-in, independent lane, part of every complete pass")
    func capabilityWiring() {
        #expect(HealthSyncCapability.clinicalLabRecords.requiresExplicitOptIn)
        #expect(HealthSyncCapability.clinicalLabRecords.source == .clinicalLabRecords)
        #expect(HealthSyncCapabilityRegistry.unsupportedEverywhere().adapter(for: .clinicalLabRecords).lane == .independent)
        #expect(HealthSyncCompositionPlan.required(for: .processing).contains(.clinicalLabRecords))
        #expect(HealthSyncCompositionPlan.required(for: .foreground).contains(.clinicalLabRecords))
    }

    // MARK: - Fakes

    static func importer(
        reader: ClinicalLabFakeReader,
        uploader: ClinicalLabFakeUploader = ClinicalLabFakeUploader { _ in ClinicalLabRecordSyncTests.response([]) },
        defaults: UserDefaults
    ) -> ClinicalLabRecordImporter {
        nonisolated(unsafe) let backing = defaults
        return ClinicalLabRecordImporter(
            reader: reader,
            uploader: uploader,
            cursors: ClinicalLabRecordCursorStore(defaults: defaults),
            isEnabled: {
                ClinicalLabRecordsConsent.syncs(
                    isAvailable: ClinicalLabRecordsGate.isAvailable(
                        readsHealthKit: true,
                        supportsHealthRecords: reader.supportsHealthRecords,
                        defaults: backing
                    ),
                    defaults: backing
                )
            },
            owner: { "owner-a" }
        )
    }
}

/// Health Records: page ends, refused calls, the resend bound.
extension ClinicalLabRecordSyncTests {
    @Test("a full page of samples with unreadable ones is not the last page")
    func unreadableSamplesDoNotEndThePass() async {
        let defaults = Self.defaults()
        ClinicalLabRecordsConsent.record(.requested, defaults: defaults)
        // 450 samples; three of the first 200 are no lab record HealthLog can read.
        let reader = ClinicalLabFakeReader(records: (0 ..< 450).map { Self.record($0) }, unreadable: [3, 50, 199])
        let uploader = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("inserted", nil) }) }
        let importer = Self.importer(reader: reader, uploader: uploader, defaults: defaults)
        guard case let .completed(outcome) = await importer.sync() else {
            Issue.record("the pass did not complete")
            return
        }
        #expect(outcome.inserted == 447, "the pass read on past the page with 197 records")
        #expect(await reader.reads == 3)
    }

    @Test("a call refused as too large or invalid is halved; only the one bad record fails")
    func refusedCallIsHalved() async {
        let defaults = Self.defaults()
        ClinicalLabRecordsConsent.record(.requested, defaults: defaults)
        let records = (0 ..< 8).map { Self.record($0) }
        let uploader = ClinicalLabFakeUploader { batch in
            if batch.count > 2 { throw HLError.server(status: 413, code: nil, message: "too large") }
            if batch.contains(where: { $0.identifier == "obs-5" }) {
                throw HLError.server(status: 422, code: "labs.fhir_batch.invalid", message: "x")
            }
            return Self.response(batch.map { _ in ("inserted", nil) })
        }
        let importer = Self.importer(reader: ClinicalLabFakeReader(records: records), uploader: uploader, defaults: defaults)
        guard case let .completed(outcome) = await importer.sync() else {
            Issue.record("the pass did not complete")
            return
        }
        #expect(outcome.inserted == 7)
        #expect(outcome.failed == 1, "only obs-5 is lost, not the call")
    }

    @Test("the resend list keeps its order, and a page that would overflow it holds the anchor")
    func resendOverflowHolds() async {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(ClinicalLabRecordImporter.merged([a, b], [b, c, a]) == [a, b, c])

        let defaults = Self.defaults()
        ClinicalLabRecordsConsent.record(.requested, defaults: defaults)
        let store = ClinicalLabRecordCursorStore(defaults: defaults)
        // 990 records still owed a resend; the first page brings 200 more that fail the same way.
        let records = (0 ..< 1200).map { Self.record($0) }
        var cursor = ClinicalLabRecordCursor()
        cursor.resend = records.suffix(990).map(\.sampleID)
        store.save(cursor, owner: "owner-a")
        let failing = ClinicalLabFakeUploader { batch in Self.response(batch.map { _ in ("failed", "write_failed") }) }
        let importer = Self.importer(reader: ClinicalLabFakeReader(records: records), uploader: failing, defaults: defaults)
        guard case .held = await importer.sync() else {
            Issue.record("the pass did not hold")
            return
        }
        let after = store.load(owner: "owner-a")
        #expect(after.anchor == nil, "the page comes again rather than being cut off")
        #expect(after.resend == records.suffix(990).map(\.sampleID), "the list is the one before the page, in order")
    }
}

/// Health Records in memory: the anchor is the count already read.
actor ClinicalLabFakeReader: ClinicalLabRecordReading {
    nonisolated let supportsHealthRecords: Bool
    private let all: [ClinicalLabRecord]
    /// Samples HealthKit hands back that do not become a lab record.
    private let unreadable: Set<Int>
    private(set) var authorizationRequests = 0
    private(set) var reads = 0

    init(records: [ClinicalLabRecord], supports: Bool = true, unreadable: Set<Int> = []) {
        all = records
        supportsHealthRecords = supports
        self.unreadable = unreadable
    }

    func requestAuthorization() async throws {
        authorizationRequests += 1
    }

    func changes(after anchor: Data?, limit: Int) async throws -> ClinicalLabChangesPage {
        reads += 1
        let start = anchor.flatMap { String(bytes: $0, encoding: .utf8) }.flatMap { Int($0) } ?? 0
        let page = Array(all.enumerated().dropFirst(start).prefix(limit))
        let records = page.filter { !unreadable.contains($0.offset) }.map(\.element)
        return ClinicalLabChangesPage(records: records, anchor: Data(String(start + page.count).utf8), read: page.count)
    }

    func records(withIDs ids: [UUID]) async throws -> [ClinicalLabRecord] {
        reads += 1
        return all.filter { ids.contains($0.sampleID) }
    }
}

/// Records every call's records (decoded back from the body) and answers.
actor ClinicalLabFakeUploader: ClinicalLabRecordUploading {
    private let answer: @Sendable ([ClinicalLabRecord]) throws -> ClinicalLabBatchResponse
    private(set) var calls: [[ClinicalLabRecord]] = []

    init(answer: @escaping @Sendable ([ClinicalLabRecord]) throws -> ClinicalLabBatchResponse) {
        self.answer = answer
    }

    func upload(_ body: Data) async throws -> ClinicalLabBatchResponse {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let entries = (json?["records"] as? [[String: Any]]) ?? []
        let batch = entries.map { entry in
            ClinicalLabRecord(
                sampleID: UUID(),
                resource: Data(),
                fhirVersion: entry["fhirVersion"] as? String,
                identifier: entry["identifier"] as? String,
                sourceURL: entry["sourceURL"] as? String,
                sourceName: entry["sourceName"] as? String
            )
        }
        calls.append(batch)
        return try answer(batch)
    }
}
