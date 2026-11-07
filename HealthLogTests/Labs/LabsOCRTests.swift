import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping file_length type_body_length

/// #149 item 3 / #151 — a lab report read by the server.
///
/// Capability on and off, the 202 run polled to its end (and resumed after a
/// cut poll), every honest limit as its own line, every refusal as its own
/// sentence, consent before anything leaves, the commit up to 400 rows, and
/// the review rules from LAB-DOC (a read "1" is never the person's "no unit").
/// Real `APIClient` + stub `URLProtocol`.
@Suite(
    "Lab report read by the server (#149, #151)",
    .serialized,
    .mockURLSession,
    .timeLimit(.minutes(1))
)
@MainActor
struct LabsOCRTests {
    private nonisolated static let lease = DocumentAIConsentLease(ownerUserID: "user-A", bearerToken: "lease-token", scope: .serverManaged)

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("session-token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeRepo(
        api: APIClient? = nil,
        consent: DocumentAIConsentLeaseProvider = DocumentAIConsentLeaseProvider { LabsOCRTests.lease }
    ) -> LabsOCRRepository {
        let api = api ?? makeAPI()
        return LabsOCRRepository(api: api, consent: consent, runs: AIRunsRepository(api: api, sleep: { _ in }))
    }

    private func makeRepo(grace: any LabUploadGraceProviding) -> LabsOCRRepository {
        let api = makeAPI()
        return LabsOCRRepository(
            api: api,
            consent: DocumentAIConsentLeaseProvider { LabsOCRTests.lease },
            runs: AIRunsRepository(api: api, sleep: { _ in }),
            uploadGrace: grace
        )
    }

    private func makeLabsStore(api: APIClient) throws -> LabsStore {
        try LabsStore(repository: LabsRepository(api: api, outbox: OutboxQueue(inMemory: true)))
    }

    private nonisolated static func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private nonisolated static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private nonisolated static let accepted = #"{"data":{"runId":"run-1","status":"QUEUED","pollAfterMs":0},"error":null}"#

    private nonisolated static func run(_ status: String, result: String = "null", error: String = "null") -> String {
        #"""
        {"data":{"id":"run-1","kind":"LABS_OCR_EXTRACT","documentId":null,"status":"\#(status)",
         "result":\#(result),"error":\#(error),"createdAt":"2026-11-05T09:00:00.000Z",
         "startedAt":null,"finishedAt":null,"queuedForMs":null,"retryAfterMs":0},"error":null}
        """#
    }

    private nonisolated static func result(rows: String = rowJSON(), extra: String = "") -> String {
        #"{"reportDate":"2026-10-30","providerType":"anthropic","rows":[\#(rows)]\#(extra)}"#
    }

    private nonisolated static func rowJSON(
        analyte: String = "Ferritin",
        value: String = "42",
        unit: String = "\"ng/ml\"",
        extra: String = ""
    ) -> String {
        #"""
        {"analyte":"\#(analyte)","value":\#(value),"valueText":null,"unit":\#(unit),"referenceLow":30,
         "referenceHigh":400,"referenceText":"30 - 400","takenAt":null,
         "confidence":{"analyte":0.9,"value":0.9,"unit":0.9,"range":0.9},"biomarkerMatch":"new",
         "markerUnit":null,"markerAnalyteKey":null,"duplicateOf":null\#(extra)}
        """#
    }

    /// Stubs extract (202) and one poll per answer in `polls`.
    private func stubRun(_ polls: [String]) {
        let index = Mutex(0)
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            if path == "/api/labs/ocr/extract" { return Self.reply(req, Self.accepted, status: 202) }
            let current = index.withLock { value -> Int in
                defer { value += 1 }
                return min(value, polls.count - 1)
            }
            return Self.reply(req, polls[current])
        }
    }

    // MARK: - Capability

    @Test("Capability on: vision with PDF; the server read is offered")
    func capabilityOn() async {
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/labs/ocr/capability")
            return Self.reply(req, #"""
            {"data":{"available":true,"mode":"vision","reason":null,"pdfSupported":true,
             "ai":{"available":true,"reason":null,"onDeviceAllowed":true}},"error":null}
            """#)
        }
        let flow = LabServerScanFlow(repository: makeRepo())
        await flow.loadCapability()
        #expect(flow.serverCanRead)
        #expect(flow.acceptsPDF)
        #expect(!flow.sendsTextOnly)
    }

    @Test(
        "Capability off: unavailable, unknown mode, or a server without the route keeps the scan on the device",
        arguments: [
            (200, #"{"data":{"available":false,"mode":null,"reason":"no-provider","pdfSupported":false},"error":null}"#),
            (200, #"{"data":{"available":true,"mode":"hologram","reason":null,"pdfSupported":true},"error":null}"#),
            (404, #"{"data":null,"error":"Not found"}"#),
            (500, #"{"data":null,"error":"boom"}"#),
        ]
    )
    func capabilityOff(status: Int, json: String) async {
        MockURLProtocol.install { req in Self.reply(req, json, status: status) }
        let flow = LabServerScanFlow(repository: makeRepo())
        await flow.loadCapability()
        #expect(!flow.serverCanRead)
        #expect(!flow.acceptsPDF)
    }

    @Test("Text mode sends only the recognised text, as JSON")
    func capabilityTextMode() async throws {
        MockURLProtocol.install { req in
            Self.reply(req, #"{"data":{"available":true,"mode":"text","reason":null,"pdfSupported":false},"error":null}"#)
        }
        let flow = LabServerScanFlow(repository: makeRepo())
        await flow.loadCapability()
        #expect(flow.sendsTextOnly)
        #expect(!flow.acceptsPDF)

        let request = try LabsOCRRepository.extractRequest(for: .text("Ferritin 42 ng/ml"))
        let json = try JSONSerialization.jsonObject(with: #require(request.body)) as? [String: String]
        #expect(json == ["mode": "text", "text": "Ferritin 42 ng/ml"])
        #expect(request.extraHeaders["Content-Type"] == nil)
        #expect(request.extraHeaders["Prefer"] == "respond-async")
    }

    // MARK: - Extract

    @Test("202: polls QUEUED, RUNNING, SUCCEEDED; the photo goes as one JPEG part under the consent lease")
    func extractBackgroundRun() async throws {
        let paths = Mutex<[String]>([])
        let seen = Mutex<URLRequest?>(nil)
        let polls = [Self.run("QUEUED"), Self.run("RUNNING"), Self.run("SUCCEEDED", result: Self.result())]
        let index = Mutex(0)
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            paths.withLock { $0.append("\(req.httpMethod ?? "") \(path)") }
            if path == "/api/labs/ocr/extract" {
                seen.withLock { $0 = req }
                return Self.reply(req, Self.accepted, status: 202)
            }
            let current = index.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            return Self.reply(req, polls[current])
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let result = try await makeRepo().extract(.jpeg(jpeg))

        #expect(result.rows.map(\.analyte) == ["Ferritin"])
        #expect(result.reportDate == "2026-10-30")
        #expect(LabsOCRLimitLine.lines(for: result).isEmpty)
        #expect(paths.withLock { $0 } == [
            "POST /api/labs/ocr/extract",
            "GET /api/ai-runs/run-1",
            "GET /api/ai-runs/run-1",
            "GET /api/ai-runs/run-1"
        ])
        let trigger = try #require(seen.withLock { $0 })
        #expect(trigger.value(forHTTPHeaderField: "Prefer") == "respond-async")
        #expect(trigger.value(forHTTPHeaderField: "Authorization") == "Bearer lease-token")
        #expect(trigger.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(bytes: Self.body(of: trigger), encoding: .isoLatin1) ?? ""
        #expect(body.contains(#"name="file"; filename="report.jpg""#))
        #expect(body.contains("Content-Type: image/jpeg"))
    }

    @Test("A PDF goes unchanged, as application/pdf")
    func extractPDFRequest() throws {
        let pdf = Data("%PDF-1.7 report".utf8)
        let request = try LabsOCRRepository.extractRequest(for: .pdf(pdf))
        let body = try #require(request.body)
        #expect(body.range(of: pdf) != nil)
        #expect((String(bytes: body, encoding: .utf8) ?? "").contains("Content-Type: application/pdf"))
    }

    @Test("A file over 12 MiB is refused on the device, before anything is sent")
    func extractTooLargeLocally() async {
        MockURLProtocol.install { req in
            Issue.record("nothing may be sent: \(req.url?.path ?? "")")
            return Self.reply(req, "{}", status: 500)
        }
        let big = Data(count: LabsOCRRepository.maxUploadBytes + 1)
        do {
            _ = try await makeRepo().extract(.pdf(big))
            Issue.record("expected tooLarge")
        } catch {
            #expect(LabsOCRFailure(error) == .tooLarge)
        }
    }

    @Test("An older server that answers 200 hands the rows back directly")
    func extractSyncAnswer() async throws {
        MockURLProtocol.install { req in Self.reply(req, #"{"data":\#(Self.result()),"error":null}"#) }
        let result = try await makeRepo().extract(.text("Ferritin 42"))
        #expect(result.rows.count == 1)
    }

    @Test("Without consent nothing leaves the device")
    func extractWithoutConsent() async {
        MockURLProtocol.install { req in
            Issue.record("nothing may be sent without consent: \(req.url?.path ?? "")")
            return Self.reply(req, "{}", status: 500)
        }
        do {
            _ = try await makeRepo(consent: .denied).extract(.jpeg(Data([0xFF, 0xD8])))
            Issue.record("expected consentRequired")
        } catch {
            #expect(error as? DocumentAIConsentError == .consentRequired)
            #expect(LabsOCRFailure(error) == .consentRequired)
        }
    }

    @Test("Consent withdrawn while the run is polled ends the wait")
    func consentWithdrawnDuringRun() async {
        stubRun([Self.run("RUNNING")])
        let calls = Mutex(0)
        let consent = DocumentAIConsentLeaseProvider {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            // Capture and re-check before the trigger, one check after it.
            return call <= 3 ? LabsOCRTests.lease : nil
        }
        do {
            _ = try await makeRepo(consent: consent).extract(.text("x"))
            Issue.record("expected consentRequired")
        } catch {
            #expect(error as? DocumentAIConsentError == .consentRequired)
        }
    }

    @Test("A poll cut off (app in the background) is asked again, not given up")
    func pollResumesAfterTransportFailure() async throws {
        let attempts = Mutex(0)
        MockURLProtocol.install { req in
            if req.url?.path == "/api/labs/ocr/extract" { return Self.reply(req, Self.accepted, status: 202) }
            let attempt = attempts.withLock { value -> Int in
                value += 1
                return value
            }
            if attempt <= 5 { throw URLError(.networkConnectionLost) }
            return Self.reply(req, Self.run("SUCCEEDED", result: Self.result()))
        }
        let result = try await makeRepo().extract(.text("x"))
        #expect(result.rows.count == 1)
        #expect(attempts.withLock { $0 } > 5)
    }

    @Test("A run that does not end within the wait limit ends with its own sentence")
    func runWaitLimit() async {
        MockURLProtocol.install { req in Self.reply(req, Self.run("RUNNING")) }
        let runs = AIRunsRepository(api: makeAPI(), sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        do {
            let _: LabsOCRExtractResult = try await runs.wait(for: "run-1", firstDelay: .zero, limit: .milliseconds(100))
            Issue.record("expected timedOut")
        } catch {
            #expect(LabsOCRFailure(error) == .timedOut)
        }
    }

    @Test("Cancelling ends the wait at once")
    func cancelEndsWait() async {
        MockURLProtocol.install { req in Self.reply(req, Self.run("RUNNING")) }
        let runs = AIRunsRepository(api: makeAPI(), sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let task = Task {
            let _: LabsOCRExtractResult = try await runs.wait(for: "run-1", firstDelay: .zero)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let outcome = await task.result
        #expect(throws: (any Error).self) { try outcome.get() }
    }

    // MARK: - Limits

    @Test("Every limit is its own calm line, in reading order")
    func limitLines() throws {
        let json = Self.result(extra: #"""
        ,"pageCoverage":{"read":20,"total":31},"truncated":{"pages":[2,3]},"unreadPages":[4],
         "stoppedBy":"budget","rowsCapped":{"kept":400,"found":512}
        """#)
        let result = try JSONDecoder.hlDefault.decode(LabsOCRExtractResult.self, from: Data(json.utf8))
        let lines = LabsOCRLimitLine.lines(for: result)
        #expect(lines == [
            .pageCoverage(read: 20, total: 31),
            .truncated(pages: [2, 3]),
            .unreadPages([4]),
            .stopped(.budget),
            .rowsCapped(kept: 400, found: 512)
        ])
    }

    @Test("A server without the limit fields reads as a complete read")
    func limitFieldsAbsent() throws {
        let result = try JSONDecoder.hlDefault.decode(LabsOCRExtractResult.self, from: Data(Self.result().utf8))
        #expect(result.truncatedPages == nil)
        #expect(result.unreadPages.isEmpty)
        #expect(result.stoppedBy == nil)
        #expect(LabsOCRLimitLine.lines(for: result).isEmpty)
    }

    @Test("A cut single read (a photo) names no page; wrongly typed fields cost only themselves")
    func limitEdgeShapes() throws {
        let json = Self.result(extra: #","truncated":{"pages":[]},"stoppedBy":"meteor","unreadPages":"x""#)
        let result = try JSONDecoder.hlDefault.decode(LabsOCRExtractResult.self, from: Data(json.utf8))
        #expect(LabsOCRLimitLine.lines(for: result) == [.truncated(pages: [])])
        #expect(result.rows.count == 1)
    }

    @Test(
        "Each limit line is a sentence, not a raw key",
        arguments: [
            LabsOCRLimitLine.truncated(pages: []), .truncated(pages: [2]), .truncated(pages: [2, 3]),
            .unreadPages([4]), .unreadPages([4, 5]), .stopped(.budget), .stopped(.unavailable),
            .stopped(.error), .pageCoverage(read: 20, total: 31), .rowsCapped(kept: 400, found: 512)
        ]
    )
    func limitSentences(line: LabsOCRLimitLine) {
        #expect(!line.message.isEmpty)
        #expect(!line.message.contains("labs.ocr"))
    }

    @Test("The page numbers appear in the sentence")
    func limitSentenceNamesPages() {
        #expect(LabsOCRLimitLine.unreadPages([4, 5]).message.contains("4"))
        #expect(LabsOCRLimitLine.unreadPages([4, 5]).message.contains("5"))
        #expect(LabsOCRLimitLine.rowsCapped(kept: 400, found: 512).message.contains("512"))
    }

    // MARK: - Refusals

    @Test(
        "Each refusal has its own sentence",
        arguments: [
            (413, "labs.ocr.fileTooLarge", LabsOCRFailure.tooLarge),
            (422, "labs.ocr.tooLarge", .tooLarge),
            (422, "labs.ocr.outputLimit", .outputLimit),
            (503, "aiRuns.readerBusy", .readerBusy),
            (415, "labs.ocr.fileType", .fileType),
            (403, "consent.ai.required", .consentRequired),
            (422, "labs.ocr.extractFailed", .failed),
        ]
    )
    func syncRefusals(status: Int, code: String, expected: LabsOCRFailure) async {
        MockURLProtocol.install { req in
            Self.reply(req, #"{"data":null,"error":"no","meta":{"errorCode":"\#(code)"}}"#, status: status)
        }
        do {
            _ = try await makeRepo().extract(.text("x"))
            Issue.record("expected \(code)")
        } catch {
            #expect(LabsOCRFailure(error) == expected)
        }
    }

    @Test(
        "A run that fails names the same refusal; the day's budget reads apart from a rate limit",
        arguments: [
            (429, "labs.ocr.budgetExceeded", LabsOCRFailure.budgetExceeded),
            (429, "rateLimit.exceeded", .rateLimited),
            (422, "labs.ocr.outputLimit", .outputLimit),
            (503, "aiRuns.readerBusy", .readerBusy),
            (504, "aiRuns.workerUnavailable", .timedOut),
            (500, "aiRuns.failed", .failed),
        ]
    )
    func runRefusals(status: Int, code: String, expected: LabsOCRFailure) async {
        stubRun([Self.run("FAILED", error: #"{"code":"\#(code)","message":"no","status":\#(status)}"#)])
        do {
            _ = try await makeRepo().extract(.text("x"))
            Issue.record("expected \(code)")
        } catch {
            #expect(LabsOCRFailure(error) == expected)
        }
    }

    @Test("A rate limit answered at once reads as rateLimited")
    func syncRateLimit() async {
        MockURLProtocol.install { req in
            Self.reply(req, #"{"data":null,"error":"slow down","meta":{"errorCode":"labs.ocr.rateLimited"}}"#, status: 429)
        }
        do {
            _ = try await makeRepo().extract(.text("x"))
            Issue.record("expected rateLimited")
        } catch {
            #expect(LabsOCRFailure(error) == .rateLimited)
        }
    }

    @Test(
        "Every failure sentence exists in German and English",
        arguments: [
            LabsOCRFailure.tooLarge, .outputLimit, .budgetExceeded, .rateLimited, .readerBusy, .fileType,
            .timedOut, .consentRequired, .unavailable, .offline, .backgroundEnded, .failed,
        ]
    )
    func failureSentences(failure: LabsOCRFailure) {
        let message = LabScanStore.Failure.server(failure).message
        #expect(!message.isEmpty)
        #expect(message != failure.messageKey)
    }

    // MARK: - Several pages without PDF

    @Test("Pages read one by one merge with their own page numbers")
    func readOneByOne() async throws {
        let cut = LabsOCRExtractResult(rows: [LabsOCRRow(analyte: "B", value: 2, unit: "g/l")], truncatedPages: [])
        let ok = LabsOCRExtractResult(rows: [LabsOCRRow(analyte: "A", value: 1, unit: "g/l")])
        let answers = [Data([1]): ok, Data([2]): cut]
        let merged = try await LabServerScanFlow.readOneByOne([Data([1]), Data([2]), Data([3])]) { page in
            guard let answer = answers[page] else {
                throw HLError.server(status: 503, code: "aiRuns.readerBusy", message: "busy")
            }
            return answer
        }
        #expect(merged.rows.map(\.analyte) == ["A", "B"])
        #expect(LabsOCRLimitLine.lines(for: merged) == [.truncated(pages: [2]), .unreadPages([3])])
    }

    @Test("A budget refusal on page 2 ends the read and names the rest as not read")
    func readOneByOneStopsOnBudget() async throws {
        let ok = LabsOCRExtractResult(rows: [LabsOCRRow(analyte: "A", value: 1, unit: "g/l")])
        let merged = try await LabServerScanFlow.readOneByOne([Data([1]), Data([2]), Data([3])]) { page in
            if page == Data([1]) { return ok }
            throw HLError.server(status: 429, code: "labs.ocr.budgetExceeded", message: "budget")
        }
        #expect(merged.unreadPages == [2, 3])
    }

    @Test("When no page produced a row, the first refusal is the answer")
    func readOneByOneAllFail() async {
        do {
            _ = try await LabServerScanFlow.readOneByOne([Data([1]), Data([2])]) { _ in
                throw HLError.server(status: 422, code: "labs.ocr.tooLarge", message: "big")
            }
            Issue.record("expected tooLarge")
        } catch {
            #expect(LabsOCRFailure(error) == .tooLarge)
        }
    }

    @Test("Merged pages keep at most 400 rows and say how many there were")
    func mergeCapsRows() {
        let rows = (0 ..< 250).map { LabsOCRRow(analyte: "M\($0)", value: 1, unit: "g/l") }
        let part = LabsOCRExtractResult(rows: rows)
        let merged = LabServerScanFlow.merge([(1, part), (2, part)], unread: [])
        #expect(merged.rows.count == 400)
        #expect(merged.rowsCapped == .init(kept: 400, found: 500))
    }

    // MARK: - Review rows

    @Test("A read \"1\" is not the person's \"no unit\": field empty, row flagged, not saveable without a unit")
    func readUnityIsNotTakenOver() {
        var row = LabScanRow(server: LabsOCRRow(analyte: "INR", value: 1.1, unit: "1"), biomarkerId: nil)
        #expect(row.unit.isEmpty)
        #expect(row.isLowConfidence)
        #expect(!row.isCommittable)
        row.noUnit = true
        #expect(row.isCommittable)
        #expect(LabScanStore.commitRow(for: row, takenAt: "2026-11-05T08:00:00Z").unit == "1")
    }

    @Test("Weak confidence, a repeat, and a unit unlike the marker's are flagged, never dropped")
    func serverFlags() {
        let weak = LabScanRow(
            server: LabsOCRRow(
                analyte: "A", value: 1, unit: "g/l",
                confidence: LabsOCRConfidence(analyte: 0.9, value: 0.3, unit: 0.9, range: 0.9)
            ),
            biomarkerId: nil
        )
        #expect(weak.isLowConfidence)
        let repeated = LabScanRow(server: LabsOCRRow(analyte: "A", value: 1, unit: "g/l", duplicateOf: "r1"), biomarkerId: nil)
        #expect(repeated.isDuplicate)
        let otherUnit = LabScanRow(
            server: LabsOCRRow(analyte: "Glucose", value: 5.4, unit: "mmol/l", markerUnit: "mg/dl"),
            biomarkerId: "bm_glu"
        )
        #expect(otherUnit.isLowConfidence)
        let qualitative = LabScanRow(server: LabsOCRRow(analyte: "Nitrit", valueText: "negativ"), biomarkerId: nil)
        #expect(qualitative.resultType == .qualitative)
        #expect(qualitative.isCommittable)
    }

    @Test("Commit rows: a linked row names its marker and its unit, a free row its own range as printed")
    func commitRows() {
        var linked = LabScanRow(
            server: LabsOCRRow(analyte: "Ferritin", value: 42, unit: nil, referenceText: "30 - 400", markerUnit: "ng/ml"),
            biomarkerId: "bm_fe"
        )
        linked.value = "42"
        let linkedBody = LabScanStore.commitRow(for: linked, takenAt: "2026-11-05T08:00:00Z")
        #expect(linkedBody.biomarkerId == "bm_fe")
        #expect(linkedBody.unit == "ng/ml")
        #expect(linkedBody.referenceText == nil)

        let free = LabScanRow(
            server: LabsOCRRow(analyte: "Ferritin", value: 42, unit: "ng/ml", referenceLow: 30, referenceText: "30 - 400"),
            biomarkerId: nil
        )
        let freeBody = LabScanStore.commitRow(for: free, takenAt: "2026-11-05T08:00:00Z")
        #expect(freeBody.biomarkerId == nil)
        #expect(freeBody.referenceText == "30 - 400")
        #expect(freeBody.referenceLow == 30)
    }

    @Test("400 rows go in one commit, 401 in two")
    func commitChunks() {
        let rows = (0 ..< 401).map { LabScanRow(server: LabsOCRRow(analyte: "M\($0)", value: 1, unit: "g/l"), biomarkerId: nil) }
        #expect(LabScanStore.commitChunks(Array(rows.prefix(400)), takenAt: "t").map(\.body.rows.count) == [400])
        #expect(LabScanStore.commitChunks(rows, takenAt: "t").map(\.body.rows.count) == [400, 1])
    }

    @Test("The report date is used when it is a real day that is not in the future")
    func reportDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // January 2027
        #expect(LabScanStore.reportDate("2026-10-30", notAfter: now) != nil)
        #expect(LabScanStore.reportDate("2099-01-01", notAfter: now) == nil)
        #expect(LabScanStore.reportDate("Oktober", notAfter: now) == nil)
        #expect(LabScanStore.reportDate(nil, notAfter: now) == nil)
    }

    // MARK: - Store: read to review to commit

    @Test("Read to review to commit: 400 rows in one request; skipped rows stay, switched off and flagged")
    func storeCommitThroughServer() async throws {
        let commits = Mutex<[Int]>([])
        let api = makeAPI()
        MockURLProtocol.install { req in
            guard req.targets("/api/labs/ocr/commit", method: "POST") else {
                return Self.reply(req, #"{"data":null,"error":"not here"}"#, status: 404)
            }
            let json = try JSONSerialization.jsonObject(with: Self.body(of: req)) as? [String: Any]
            let sent = (json?["rows"] as? [[String: Any]]) ?? []
            commits.withLock { $0.append(sent.count) }
            #expect(req.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
            let inserted = Array(repeating: "{}", count: sent.count - 1).joined(separator: ",")
            return Self.reply(req, #"""
            {"data":{"inserted":[\#(inserted)],"skipped":[{"analyte":"M0","reason":"duplicate"}],"outcome":"partial"},"error":null}
            """#)
        }
        let scan = try LabScanStore(labsStore: makeLabsStore(api: api))
        scan.ocrRepository = makeRepo(api: api)
        let rows = (0 ..< 400).map { LabsOCRRow(analyte: "M\($0)", value: 1, unit: "g/l") }
        scan.ingest(server: LabsOCRExtractResult(rows: rows, truncatedPages: [3]))
        #expect(scan.origin == .server)
        #expect(scan.step == .review)
        #expect(scan.readLimits == [.truncated(pages: [3])])
        #expect(scan.includedCount == 400)

        let done = await scan.commit()
        #expect(!done)
        #expect(commits.withLock { $0 } == [400])
        #expect(scan.rows.map(\.analyte) == ["M0"])
        #expect(scan.rows.first?.isIncluded == false)
        #expect(scan.saveSummary?.contains("399") == true)
    }

    @Test("A commit that does not get through keeps every row for another try")
    func storeCommitFails() async throws {
        let api = makeAPI()
        MockURLProtocol.install { req in Self.reply(req, #"{"data":null,"error":"bad"}"#, status: 422) }
        let scan = try LabScanStore(labsStore: makeLabsStore(api: api))
        scan.ocrRepository = makeRepo(api: api)
        scan.ingest(server: LabsOCRExtractResult(rows: [LabsOCRRow(analyte: "A", value: 1, unit: "g/l")]))
        let done = await scan.commit()
        #expect(!done)
        #expect(scan.rows.count == 1)
        #expect(scan.saveSummary == String(localized: "labs.ocr.saveFailed"))
    }

    @Test("A read without rows says so; starting over clears the limits and the origin")
    func storeEmptyAndRetake() throws {
        let scan = try LabScanStore(labsStore: makeLabsStore(api: makeAPI()))
        scan.ingest(server: LabsOCRExtractResult(rows: []))
        #expect(scan.failure == .noRows)
        scan.ingest(server: LabsOCRExtractResult(rows: [LabsOCRRow(analyte: "A", value: 1, unit: "g/l")], unreadPages: [2]))
        #expect(scan.readLimits == [.unreadPages([2])])
        scan.retake()
        #expect(scan.readLimits.isEmpty)
        #expect(scan.origin == .device)
    }

    @Test("A failed read lands on the chooser with its own sentence; local stops keep theirs")
    func flowFailureMapping() {
        #expect(LabServerScanFlow.failure(for: LabServerScanFlow.LocalStop.noText) == .noText)
        #expect(LabServerScanFlow.failure(for: HLError.server(status: 503, code: "aiRuns.readerBusy", message: "")) ==
            .server(.readerBusy))
        #expect(LabServerScanFlow.failure(for: HLError.offline) == .server(.offline))
    }

    // MARK: - Upload grace (POLISH-A A4)

    @Test("The upload runs inside a grace window that ends once; the read goes on as before")
    func uploadInsideGraceWindow() async throws {
        stubRun([Self.run("SUCCEEDED", result: Self.result())])
        let grace = RecordingGrace(expireAfter: nil)
        let result = try await makeRepo(grace: grace).extract(.jpeg(Data([0xFF, 0xD8, 0xFF])))
        #expect(result.rows.map(\.analyte) == ["Ferritin"])
        #expect(grace.begun == 1)
        #expect(grace.ended == 1)
    }

    @Test("When the grace time runs out mid-upload, the read ends with its own sentence, not \"no connection\"")
    func uploadGraceExpires() async throws {
        MockURLProtocol.install { req in
            Thread.sleep(forTimeInterval: 1.5)
            return Self.reply(req, Self.accepted, status: 202)
        }
        let grace = RecordingGrace(expireAfter: .milliseconds(150))
        do {
            _ = try await makeRepo(grace: grace).extract(.jpeg(Data([0xFF, 0xD8, 0xFF])))
            Issue.record("expected the upload to end")
        } catch {
            #expect(error as? LabUploadInterrupted == .backgroundTimeEnded)
            #expect(LabsOCRFailure(error) == .backgroundEnded)
            #expect(LabServerScanFlow.failure(for: error) == .server(.backgroundEnded))
            #expect(LabsOCRFailure(error).messageKey == "labs.ocr.error.backgroundEnded")
        }
        #expect(grace.ended == 1)
    }
}

/// A grace window that records begin and end and, when asked, expires after a
/// delay the way iOS would.
private final class RecordingGrace: LabUploadGraceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0
    private var ends = 0
    private let expireAfter: Duration?

    init(expireAfter: Duration?) {
        self.expireAfter = expireAfter
    }

    var begun: Int {
        lock.withLock { begins }
    }

    var ended: Int {
        lock.withLock { ends }
    }

    func begin(name _: String, onExpiry: @escaping @Sendable () -> Void) async -> @Sendable () async -> Void {
        lock.withLock { begins += 1 }
        if let expireAfter {
            Task {
                try? await Task.sleep(for: expireAfter)
                onExpiry()
            }
        }
        return { [self] in lock.withLock { ends += 1 } }
    }
}
