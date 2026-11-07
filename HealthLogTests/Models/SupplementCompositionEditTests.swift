import Foundation
@testable import HealthLog
import ImageIO
import Synchronization
import Testing
import UIKit
import UniformTypeIdentifiers

// swiftlint:disable force_unwrapping file_length type_body_length

/// SUPP-EDIT (1.5.0, #131 P3) — editing a supplement's composition, also
/// from a label photo (server v1.43, notes of 15.10.: HEIC is refused, a
/// label is read only on the own record).
///
/// The catalogue builds the form, the PUT carries `MANUAL` or `LABEL_AI`, a
/// proposal is stored only by Save, every refusal has its own sentence, and
/// the photo always leaves as JPEG. Real `APIClient` + stub `URLProtocol`.
@Suite(
    "SUPP-EDIT — composition editor and label photo",
    .serialized,
    .mockURLSession,
    .timeLimit(.minutes(1))
)
@MainActor
struct SupplementCompositionEditTests {
    private static let de = Locale(identifier: "de_DE")

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

    private func makeRepo(_ api: APIClient? = nil) -> MedicationIngredientsRepository {
        let api = api ?? makeAPI()
        return MedicationIngredientsRepository(api: api, runs: AIRunsRepository(api: api, sleep: { _ in }))
    }

    private nonisolated static func reply(
        _ request: URLRequest,
        _ json: String,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(json.utf8))
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

    private struct SeenRequest {
        let method: String
        let path: String
        let body: Data
        let key: String?
    }

    private nonisolated static func error(_ code: String) -> String {
        #"{"data":null,"error":"refused","meta":{"errorCode":"\#(code)"}}"#
    }

    // MARK: - Fixtures

    private nonisolated static let catalogJSON = #"""
    {"data":{"entries":[
     {"code":"vitamin_d","unit":"ug","labelKey":"nutrients.names.vitamin_d","label":"Vitamin D","syncable":true,
      "inputUnits":[{"unit":"ug","factorToCanonical":1},{"unit":"mg","factorToCanonical":1000},{"unit":"IU","factorToCanonical":0.025}],
      "upperLimit":{"value":100,"unit":"ug","scope":"total","source":"EFSA 2023","form":null}},
     {"code":"magnesium","unit":"mg","labelKey":"nutrients.names.magnesium","label":"Magnesium","syncable":true,
      "inputUnits":[{"unit":"mg","factorToCanonical":1},{"unit":"ug","factorToCanonical":0.001},{"unit":"g","factorToCanonical":1000}],
      "upperLimit":null},
     {"code":"dha","unit":"mg","labelKey":"nutrients.names.dha","label":"DHA (Omega-3)","syncable":false,
      "inputUnits":[{"unit":"mg","factorToCanonical":1},{"broken":true}],"upperLimit":null},
     {"code":"water","unit":"ml","labelKey":"nutrients.names.water","label":"Wasser","syncable":true,
      "inputUnits":[{"unit":"ml","factorToCanonical":1}],"upperLimit":null},
     {"label":"no code"}
    ]},"error":null}
    """#

    private nonisolated static let accepted = #"{"data":{"runId":"run-1","status":"QUEUED","pollAfterMs":0},"error":null}"#

    private nonisolated static func run(_ status: String, result: String = "null", error: String = "null") -> String {
        #"""
        {"data":{"id":"run-1","kind":"SUPPLEMENT_LABEL_EXTRACT","documentId":null,"status":"\#(status)",
         "result":\#(result),"error":\#(error),"createdAt":"2026-11-05T09:00:00.000Z",
         "startedAt":null,"finishedAt":null,"queuedForMs":null,"retryAfterMs":0},"error":null}
        """#
    }

    private nonisolated static let proposalJSON = #"""
    {"ingredients":[
      {"nutrient":"vitamin_d","amount":1000,"unit":"IU","confidence":"high","printedText":"Vitamin D3 1000 IE"},
      {"nutrient":"magnesium","amount":187.5,"unit":"mg","confidence":"low","printedText":"Magnesium 375 mg"},
      {"nutrient":"unobtainium","amount":5,"unit":"mg","confidence":"high","printedText":"Coenzym Q10 5 mg"}],
     "unmatched":[{"printedText":"Füllstoff: Cellulose"}],
     "servingNote":"pro 2 Kapseln"}
    """#

    private func catalog() throws -> NutrientServerCatalog {
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<NutrientServerCatalog>.self, from: Data(Self.catalogJSON.utf8))
        return try #require(envelope.data)
    }

    private static let existing = [
        MedicationIngredient(
            nutrient: "vitamin_d",
            amountPerUnit: 25,
            unit: "ug",
            enteredAmount: 1000,
            enteredUnit: "IU",
            label: "Vitamin D"
        )
    ]

    /// A model whose catalogue is loaded through the stub.
    private func loadedModel(
        lines: [MedicationIngredient] = existing,
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data?)
    ) async -> MedicationCompositionEditorModel {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/nutrients/catalog" { return Self.reply(req, Self.catalogJSON) }
            return handler(req)
        }
        let model = MedicationCompositionEditorModel(medicationID: "med_d3", lines: lines, repository: makeRepo(), locale: Self.de)
        await model.loadCatalog()
        return model
    }

    // MARK: - Catalogue

    @Test("The catalogue builds the form: server names, input units in order, water and broken entries left out")
    func catalogueDecodes() throws {
        let catalog = try catalog()
        #expect(catalog.entries.map(\.code) == ["vitamin_d", "magnesium", "dha", "water"], "an entry without a code is dropped")
        #expect(catalog.ingredientEntries.map(\.code) == ["vitamin_d", "magnesium", "dha"], "water is never an ingredient")
        #expect(catalog.entry(for: "vitamin_d")?.offeredUnits == ["ug", "mg", "IU"])
        #expect(catalog.entry(for: "dha")?.offeredUnits == ["mg"], "a broken input unit costs only itself")
        #expect(catalog.entry(for: "dha")?.displayName == "DHA (Omega-3)")
        #expect(catalog.entry(for: "dha")?.syncable == false)
    }

    @Test("Server without the catalogue (404) cannot edit; the module off shows the disabled card")
    func catalogueRefusals() async {
        MockURLProtocol.install { req in Self.reply(req, Self.error("not_found"), status: 404) }
        let older = MedicationCompositionEditorModel(medicationID: "m", lines: [], repository: makeRepo())
        await older.loadCatalog()
        #expect(older.catalogState == .failed)
        #expect(!older.canSave)

        MockURLProtocol.install { req in
            Self.reply(req, #"{"data":null,"error":"off","meta":{"errorCode":"module.disabled","module":"nutrients"}}"#, status: 403)
        }
        let off = MedicationCompositionEditorModel(medicationID: "m", lines: [], repository: makeRepo(), offReason: { "off" })
        await off.loadCatalog()
        #expect(off.catalogState == .disabled("off"))
    }

    @Test("Server without the field gets no link; with the field (even empty) the composition is editable")
    func linkFollowsTheField() throws {
        let older = try JSONDecoder.hlDefault.decode(
            MedicationWireDTO.self,
            from: Data(#"{"id":"m","name":"D3","dose":"1","active":true,"schedules":[]}"#.utf8)
        ).toDomain()
        let model = MedicationCompositionModel()
        model.apply(older)
        #expect(!model.serverKnowsComposition)

        let newer = try JSONDecoder.hlDefault.decode(
            MedicationWireDTO.self,
            from: Data(
                #"{"id":"m","name":"D3","dose":"1","active":true,"schedules":[],"category":"SUPPLEMENT","hasIngredients":false,"ingredients":[]}"#
                    .utf8
            )
        ).toDomain()
        model.apply(newer)
        #expect(model.serverKnowsComposition)
        #expect(model.state == .loaded([]))
        #expect(MedicationCompositionAccess.offersEmptyComposition(category: newer.category))
        #expect(!MedicationCompositionAccess.offersEmptyComposition(category: "CARDIO"))
        #expect(!MedicationCompositionAccess.offersEmptyComposition(category: nil))
    }

    // MARK: - Rows and save

    @Test("Existing lines open as entered (1.000 IE stays 1000 IU), unchanged saves nothing")
    func opensAsEntered() async {
        let model = await loadedModel { req in Self.reply(req, "{}", status: 500) }
        #expect(model.rows.count == 1)
        #expect(model.rows[0].nutrient == "vitamin_d")
        #expect(model.rows[0].amountText == "1000", "no grouping in the field")
        #expect(model.rows[0].unit == "IU")
        #expect(!model.hasChanges)
        #expect(!model.canSave)
    }

    @Test("Save sends PUT …/ingredients with MANUAL, the typed amount and unit, and one key per body")
    func saveManual() async throws {
        let seen = Mutex<[SeenRequest]>([])
        let model = await loadedModel { req in
            seen.withLock { $0.append(SeenRequest(
                method: req.httpMethod ?? "",
                path: req.url?.path ?? "",
                body: Self.body(of: req),
                key: req.value(forHTTPHeaderField: "Idempotency-Key")
            )) }
            if seen.withLock({ $0.count }) == 1 { return Self.reply(req, "{}", status: 500) }
            return Self.reply(req, #"""
            {"data":{"ingredients":[{"nutrient":"vitamin_d","amountPerUnit":25,"unit":"ug","enteredAmount":1000,"enteredUnit":"IU","labelKey":"k","label":"Vitamin D"},
             {"nutrient":"magnesium","amountPerUnit":1.5,"unit":"mg","enteredAmount":null,"enteredUnit":null,"labelKey":"k","label":"Magnesium"}],
             "recompute":{"queued":true}},"error":null}
            """#)
        }
        model.addRow()
        let row = try #require(model.rows.last)
        model.choose(nutrient: "magnesium", for: row.id)
        #expect(model.rows.last?.unit == "mg", "choosing a nutrient sets its canonical unit")
        #expect(!model.canSave, "no amount yet")
        model.setAmount("1,5", for: row.id)
        #expect(model.canSave)
        #expect(model.takenCodes(except: row.id) == ["vitamin_d"], "a nutrient is offered once")

        #expect(await model.save() == false, "first answer 500")
        #expect(model.saveError == String(localized: "medications.composition.edit.error.generic"))
        #expect(await model.save())

        let requests = seen.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.method == "PUT" && $0.path == "/api/medications/med_d3/ingredients" })
        #expect(requests[0].key != nil && requests[0].key == requests[1].key, "a retry of the same body keeps its key")
        let json = try #require(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
        #expect(json["source"] as? String == "MANUAL")
        let lines = try #require(json["ingredients"] as? [[String: Any]])
        #expect(lines.count == 2)
        #expect(lines[0]["nutrient"] as? String == "vitamin_d")
        #expect(lines[0]["amount"] as? Double == 1000)
        #expect(lines[0]["unit"] as? String == "IU")
        #expect(lines[1]["amount"] as? Double == 1.5, "German decimal comma read")
        #expect(Set(lines[1].keys) == ["nutrient", "amount", "unit"], "nothing else on the wire")
    }

    @Test("At most 40 rows; an empty composition can be saved to clear it")
    func rowLimitAndClear() async {
        let puts = Mutex(0)
        let model = await loadedModel { req in
            puts.withLock { $0 += 1 }
            let json = try? JSONSerialization.jsonObject(with: Self.body(of: req)) as? [String: Any]
            #expect((json?["ingredients"] as? [Any])?.isEmpty == true)
            return Self.reply(req, #"{"data":{"ingredients":[],"recompute":{"queued":false}},"error":null}"#)
        }
        for _ in 0 ..< 45 {
            model.addRow()
        }
        #expect(model.rows.count == 40)
        #expect(!model.canAddRow)
        for row in model.rows {
            model.remove(row.id)
        }
        #expect(model.canSave, "removing every line is a change")
        #expect(await model.save())
        #expect(puts.withLock { $0 } == 1)
    }

    @Test("422 unitMismatch marks the row with the units the catalogue allows")
    func unitMismatchMarksRow() async {
        let model = await loadedModel { req in
            Self.reply(req, Self.error("medications.ingredients.unitMismatch"), status: 422)
        }
        // A unit the current catalogue no longer offers for the nutrient.
        model.rows[0].unit = "IE-old"
        #expect(await model.save() == false)
        #expect(model.saveError == String(localized: "medications.composition.edit.error.unitMismatch"))
        #expect(model.rows[0].allowedUnits == ["ug", "mg", "IU"])
        model.setUnit("ug", for: model.rows[0].id)
        #expect(model.rows[0].allowedUnits == nil)
    }

    @Test("Refused saves each have a sentence", arguments: [
        (422, "medications.ingredients.invalid", "medications.composition.edit.error.invalid"),
        (403, "sharing.access.denied", "medications.composition.edit.error.notAllowed"),
        (404, "medications.notFound", "medications.composition.edit.error.gone")
    ])
    func saveRefusals(status: Int, code: String, key: String) async {
        let model = await loadedModel { req in Self.reply(req, Self.error(code), status: status) }
        model.setAmount("2000", for: model.rows[0].id)
        #expect(await model.save() == false)
        #expect(model.saveError == String(localized: String.LocalizationValue(key)))
    }

    // MARK: - Label photo

    @Test("A label proposal fills the form, flags the unsure line, and is stored only by Save with LABEL_AI")
    func proposalNeedsSave() async throws {
        let paths = Mutex<[String]>([])
        let putBody = Mutex<Data?>(nil)
        let model = await loadedModel { req in
            let path = req.url?.path ?? ""
            paths.withLock { $0.append("\(req.httpMethod ?? "") \(path)") }
            switch path {
            case "/api/medications/med_d3/ingredients/extract":
                #expect(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
                let body = Self.body(of: req)
                #expect(String(bytes: body, encoding: .isoLatin1)?.contains("Content-Type: image/jpeg") == true)
                return Self.reply(req, Self.accepted, status: 202)
            case "/api/ai-runs/run-1":
                return Self.reply(req, Self.run("SUCCEEDED", result: Self.proposalJSON))
            default:
                putBody.withLock { $0 = Self.body(of: req) }
                return Self.reply(req, #"{"data":{"ingredients":[],"recompute":{"queued":true}},"error":null}"#)
            }
        }
        model.readLabel(jpeg: Self.jpegBytes())
        #expect(model.isReading)
        while model.isReading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.labelError == nil)
        #expect(model.rows.map(\.nutrient) == ["vitamin_d", "magnesium"])
        #expect(model.rows[0].unit == "IU" && model.rows[0].amountText == "1000" && !model.rows[0].needsCheck)
        #expect(model.rows[1].amountText == "187,5" && model.rows[1].needsCheck, "confidence low asks for a check")
        let proposal = try #require(model.proposal)
        #expect(proposal.servingNote == "pro 2 Kapseln")
        #expect(
            proposal.unmatched == ["Füllstoff: Cellulose", "Coenzym Q10 5 mg"],
            "a code outside the catalogue joins the unmatched lines"
        )
        #expect(model.source == .labelAI)
        #expect(!paths.withLock { $0 }.contains { $0.hasPrefix("PUT") }, "nothing stored before Save")

        #expect(await model.save())
        let stored = try #require(putBody.withLock { $0 })
        let json = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(json["source"] as? String == "LABEL_AI")
        #expect(paths.withLock { $0 } == [
            "POST /api/medications/med_d3/ingredients/extract",
            "GET /api/ai-runs/run-1",
            "PUT /api/medications/med_d3/ingredients"
        ])
    }

    @Test("Every refused label read has its own sentence, never a raw key", arguments: [
        (422, "medications.ingredients.extract.fileType", SupplementLabelReadFailure.fileType),
        (413, "medications.ingredients.extract.fileTooLarge", .fileTooLarge),
        (403, "consent.ai.required", .unavailable),
        (422, "ai.provider.none", .unavailable),
        (503, "aiRuns.readerBusy", .busy)
    ])
    func syncRefusals(status: Int, code: String, expected: SupplementLabelReadFailure) async throws {
        let model = await loadedModel { req in Self.reply(req, Self.error(code), status: status) }
        model.readLabel(jpeg: Self.jpegBytes())
        while model.isReading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.labelError == expected.message)
        #expect(model.rows.count == 1, "the form stays as it was")
        #expect(model.source == .manual)
    }

    @Test("429: the hourly limit (Retry-After) and the day's budget (none) read apart")
    func rateLimitAndBudget() async throws {
        let model = await loadedModel { req in
            Self.reply(req, Self.error("medications.ingredients.extract.rateLimited"), status: 429, headers: ["Retry-After": "1800"])
        }
        model.readLabel(jpeg: Self.jpegBytes())
        while model.isReading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.labelError == SupplementLabelReadFailure.rateLimited.message)

        let budget = await loadedModel { req in
            Self.reply(req, Self.error("medications.ingredients.extract.budgetExceeded"), status: 429)
        }
        budget.readLabel(jpeg: Self.jpegBytes())
        while budget.isReading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(budget.labelError == SupplementLabelReadFailure.budgetExceeded.message)
    }

    @Test("A failed run says so; a run that hits the budget keeps the budget's sentence", arguments: [
        (#"{"code":"medications.ingredients.extract.failed","message":"x","status":422}"#, SupplementLabelReadFailure.failed),
        (#"{"code":"medications.ingredients.extract.budgetExceeded","message":"x","status":429}"#, .budgetExceeded),
        (#"{"code":"aiRuns.workerUnavailable","message":"x","status":503}"#, .busy)
    ])
    func runFailures(error: String, expected: SupplementLabelReadFailure) async throws {
        let model = await loadedModel { req in
            if req.url?.path.hasSuffix("/extract") == true { return Self.reply(req, Self.accepted, status: 202) }
            return Self.reply(req, Self.run("FAILED", error: error))
        }
        model.readLabel(jpeg: Self.jpegBytes())
        while model.isReading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.labelError == expected.message)
        #expect(model.proposal == nil)
    }

    @Test("Every label and save sentence resolves in German and English, never to its key")
    func sentencesResolve() throws {
        let failures: [SupplementLabelReadFailure] = [
            .fileType, .fileTooLarge, .rateLimited, .budgetExceeded, .failed, .unavailable, .busy, .offline, .unreadable
        ]
        for failure in failures {
            #expect(!failure.message.hasPrefix("medications."), "raw key for \(failure)")
        }
        #expect(Set(failures.map(\.message)).count == failures.count, "each its own sentence")
        let keys = [
            "fileType", "fileTooLarge", "rateLimited", "budgetExceeded", "failed", "unavailable", "busy", "offline", "unreadable"
        ].map { "medications.composition.label.error.\($0)" } + [
            "medications.composition.edit.link", "medications.composition.edit.add", "medications.composition.edit.title",
            "medications.composition.edit.error.unitMismatch", "medications.composition.edit.error.generic",
            "medications.composition.label.choosePhoto", "medications.composition.label.footer",
            "medications.composition.label.reviewNote", "medications.composition.label.lowConfidence",
            "medications.composition.label.servingNote %@", "medications.composition.edit.allowedUnits %@"
        ]
        for language in ["de", "en"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language).lproj")
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}missing", table: nil)
                #expect(value != "\u{0}missing" && value != key, "\(key) in \(language)")
            }
        }
    }

    // MARK: - JPEG seam

    @Test("A HEIC photo leaves as JPEG; a non-JPEG never reaches the wire")
    func heicBecomesJPEG() throws {
        let heic = try #require(Self.encoded(Self.sampleImage(side: 600), type: UTType.heic), "simulator can write HEIC")
        #expect(
            heic.count > 12 && String(bytes: heic[4 ..< 12], encoding: .ascii)?.hasPrefix("ftyphei") == true,
            "the input really is HEIC"
        )
        #expect(!MedicationIngredientsRepository.isJPEG(heic))

        let jpeg = try MedicationIngredientsRepository.labelJPEG(from: heic)
        #expect(MedicationIngredientsRepository.isJPEG(jpeg))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)

        #expect(throws: HLError.self) {
            _ = try MedicationIngredientsRepository.extractRequest(medicationID: "m", jpeg: heic)
        }
        let request = try MedicationIngredientsRepository.extractRequest(medicationID: "m", jpeg: jpeg)
        #expect(request.path == "/api/medications/m/ingredients/extract")
        #expect(request.maxRetries == 0, "a read is charged; never re-sent")
        let body = String(data: request.body ?? Data(), encoding: .isoLatin1) ?? ""
        #expect(body.contains("filename=\"label.jpg\""))
        #expect(body.contains("Content-Type: image/jpeg"))
    }

    @Test("A photo over the limit is made smaller until it fits, still JPEG")
    func shrinksToLimit() throws {
        let png = try #require(Self.encoded(Self.sampleImage(side: 1600), type: UTType.png))
        let limit = 60000
        let jpeg = try MedicationIngredientsRepository.labelJPEG(from: png, limit: limit)
        #expect(jpeg.count <= limit)
        #expect(MedicationIngredientsRepository.isJPEG(jpeg))
        #expect(throws: SupplementLabelReadFailure.unreadable) {
            _ = try MedicationIngredientsRepository.labelJPEG(from: Data("not an image".utf8))
        }
        #expect(throws: HLError.self) {
            _ = try MedicationIngredientsRepository.extractRequest(
                medicationID: "m",
                jpeg: Data([0xFF, 0xD8, 0xFF]) + Data(count: MedicationIngredientsRepository.maxUploadBytes)
            )
        }
    }

    // MARK: - Who may do what

    @Test("Photo only on the own record, with the capability, never on frugal; editing at MANAGE")
    func access() throws {
        let entries = try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(#"""
        [{"accountId":"a-1","username":"carer","level":"write","recordKind":"shared","sections":["medications"],"canWrite":true},
         {"accountId":"a-2","username":"manager","level":"manage","recordKind":"shared","sections":null,"canWrite":true}]
        """#.utf8))
        let writer = AccountAccess(accounts: entries, active: entries[0], recordKind: .shared, canSwitch: true)
        let manager = AccountAccess(accounts: entries, active: entries[1], recordKind: .shared, canSwitch: true)
        let own = AccountAccess.ownerOnly
        let on = AICapabilityState(available: true, reason: nil, onDeviceAllowed: false)
        let usageOff = AICapabilityState(available: false, reason: .usageLevel, onDeviceAllowed: false)

        #expect(MedicationCompositionAccess.canEdit(own))
        #expect(MedicationCompositionAccess.canEdit(manager), "a delegate at MANAGE may edit")
        #expect(!MedicationCompositionAccess.canEdit(writer), "WRITE is not enough for the composition")

        func photo(_ access: AccountAccess, _ state: AICapabilityState, reports: Bool = true, usage: AIUsageLevel? = .standard) -> Bool {
            MedicationCompositionAccess.offersLabelPhoto(access: access, reportsCapabilities: reports, capability: state, usage: usage)
        }
        #expect(photo(own, on))
        #expect(!photo(manager, on), "never for a delegate")
        #expect(!photo(own, on, usage: .frugal), "frugal: no photo")
        #expect(!photo(own, usageOff), "the server's usage_level refusal")
        #expect(!photo(own, .legacy, reports: false), "a server without the ai block offers none")
        #expect(!photo(own, .absent))
    }

    @Test("Typed amounts: comma or dot, no letters, no grouping")
    func amountParsing() {
        #expect(MedicationCompositionEditorModel.parseAmount("1,5", locale: Self.de) == 1.5)
        #expect(MedicationCompositionEditorModel.parseAmount("1.5", locale: Self.de) == 1.5)
        #expect(MedicationCompositionEditorModel.parseAmount("1.000,5", locale: Self.de) == nil, "ambiguous grouping is refused")
        #expect(MedicationCompositionEditorModel.parseAmount("abc", locale: Self.de) == nil)
        #expect(MedicationCompositionEditorModel.parseAmount("", locale: Self.de) == nil)
        #expect(MedicationCompositionEditorModel.amountText(0.025, locale: Self.de) == "0,025")
        #expect(MedicationCompositionEditorModel.amountText(1000, locale: Locale(identifier: "en_US")) == "1000")
    }

    // MARK: - Images

    private static func sampleImage(side: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            // Noise, so a JPEG cannot squeeze it to nothing.
            var generator = SystemRandomNumberGenerator()
            for x in stride(from: 0, to: side, by: 8) {
                for y in stride(from: 0, to: side, by: 8) {
                    UIColor(
                        red: .random(in: 0 ... 1, using: &generator),
                        green: .random(in: 0 ... 1, using: &generator),
                        blue: .random(in: 0 ... 1, using: &generator),
                        alpha: 1
                    ).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
    }

    private static func encoded(_ image: UIImage, type: UTType) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func jpegBytes() -> Data {
        sampleImage(side: 32).jpegData(compressionQuality: 0.85)!
    }
}
