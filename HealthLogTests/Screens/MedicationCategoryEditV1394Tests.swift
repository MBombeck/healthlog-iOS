import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **R1 — editing a medication keeps its category (server v1.39.4 #1041,
/// still open on v1.39.6, point 3).**
///
/// The server's category list is `BLOOD_PRESSURE, VITAMIN, SUPPLEMENT,
/// PAIN_RELIEF, ALLERGY, DIGESTIVE, THYROID, HORMONE, SKIN, SLEEP_AID, DIABETES,
/// ANTIBIOTIC, MENTAL_HEALTH, OTHER` (`MEDICATION_CATEGORY_VALUES`, v1.39.4). The
/// editor lacked the last three but OTHER, opened any category it did not know
/// on "Other" and always sent `category` — so moving the dose time of a
/// diabetes medication stored OTHER. The PUT now names `category` (and
/// `treatmentClass`) only when that row changed, like `unitsPerDose`, and an
/// unknown category opens as itself.
@Suite("v1.39.4 #1041 — the medication editor keeps the category", .serialized, .mockURLSession)
struct MedicationCategoryEditV1394Tests {
    static func json(category: String, treatmentClass: String = "GENERIC") -> String {
        """
        {"id":"med-dia","name":"Metformin","dose":"500 mg","treatmentClass":"\(treatmentClass)","dosesPerUnit":null,\
        "unitsPerDose":1,"active":true,"notificationsEnabled":true,"liveActivityEnabled":false,\
        "criticalAlarmEnabled":false,"pausedAt":null,"snoozedUntil":null,"nextDueAt":null,"nextDueOverdue":false,\
        "startsOn":null,"endsOn":null,"oneShot":false,"asNeeded":false,"trackIntake":true,\
        "courseStatus":"CURRENT","intakeActionable":true,"createdAt":"2026-09-01T08:00:00.000Z",\
        "schedules":[\(MedicationTrackIntakeV1391Tests.schedule("08:00"))],"category":"\(category)",\
        "externalSource":null,"lastTakenAt":null,"todayEventCount":0,"stockDosesRemaining":null,"runwayDays":null}
        """
    }

    static func medication(category: String, treatmentClass: String = "GENERIC") throws -> Medication {
        try JSONDecoder.hlDefault.decode(
            MedicationWireDTO.self, from: Data(json(category: category, treatmentClass: treatmentClass).utf8)
        ).toDomain()
    }

    // MARK: - Picker rows and labels

    @Test("the picker offers every server category, the three new ones labelled en + de")
    func pickerRows() {
        #expect(MedicationCategoryOption(rawValue: "DIABETES") == .diabetes)
        #expect(MedicationCategoryOption(rawValue: "ANTIBIOTIC") == .antibiotic)
        #expect(MedicationCategoryOption(rawValue: "MENTAL_HEALTH") == .mentalHealth)
        #expect(MedicationCategoryOption.diabetes.displayName == "Diabetes")
        #expect(MedicationCategoryOption.antibiotic.displayName == "Antibiotikum")
        #expect(MedicationCategoryOption.mentalHealth.displayName == "Psychische Gesundheit")
        #expect(MedicationCard.localizedCategory("MENTAL_HEALTH") == "Psychische Gesundheit")
        #expect(MedicationCard.localizedCategory("ANTIBIOTIC") == "Antibiotikum")
    }

    @Test("a known category opens on its row; an unknown one opens as itself, never as Other")
    func prefill() throws {
        #expect(try EditMedicationFormState(from: Self.medication(category: "DIABETES")).category == .diabetes)
        #expect(try EditMedicationFormState(from: Self.medication(category: "OPHTHALMIC")).category == nil)
    }

    // MARK: - What the PUT names

    @Test("moving the dose time of a diabetes medication: the exact body, no category, no class")
    @MainActor
    func timeOnlyEditExactBody() async throws {
        let served = try Self.medication(category: "DIABETES")
        var draft = MedicationEditDraft(prefill: EditMedicationFormState(from: served))
        draft.times = [TimeOfDay(hour: 9, minute: 0)]

        nonisolated(unsafe) var captured: [String: Any]?
        nonisolated(unsafe) var method: String?
        let response = #"{"data":"# + Self.json(category: "DIABETES") + "}"
        MockURLProtocol.install { req in
            method = req.httpMethod
            captured = Self.bodyData(req).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (Self.ok(req), Data(response.utf8))
        }
        let repo = try MedicationsRepository(api: Self.makeAPI(), outbox: OutboxQueue(inMemory: true))
        _ = try await repo.update(id: served.id, patch: draft.patch(for: served))

        let body = try #require(captured)
        #expect(method == "PUT")
        #expect(Set(body.keys) == ["name", "dose", "active", "notificationsEnabled", "schedules", "oneShot", "asNeeded"])
        #expect(body["name"] as? String == "Metformin")
        #expect(body["dose"] as? String == "500 mg")
        #expect(body["active"] as? Bool == true)
        #expect(body["notificationsEnabled"] as? Bool == true)
        #expect(body["oneShot"] as? Bool == false)
        #expect(body["asNeeded"] as? Bool == false)
        let schedules = try #require(body["schedules"] as? [[String: Any]])
        #expect(schedules.count == 1)
        #expect(schedules.first?["timesOfDay"] as? [String] == ["09:00"])
        #expect(schedules.first?["rrule"] as? String == "FREQ=DAILY")
        #expect(body["category"] == nil)
        #expect(body["treatmentClass"] == nil)
    }

    @Test("an untouched save of an unknown category names neither category nor schedule")
    func untouchedUnknownCategory() throws {
        let served = try Self.medication(category: "OPHTHALMIC", treatmentClass: "GLP1")
        let patch = MedicationEditDraft(prefill: EditMedicationFormState(from: served)).patch(for: served)
        #expect(patch.category == nil)
        #expect(patch.treatmentClass == nil)
        #expect(patch.schedules == nil)
    }

    @Test("a changed category or class row is sent as chosen")
    func changedRowsAreSent() throws {
        let served = try Self.medication(category: "OPHTHALMIC")
        var draft = MedicationEditDraft(prefill: EditMedicationFormState(from: served))
        draft.category = .mentalHealth
        draft.treatmentClass = .glp1
        let patch = draft.patch(for: served)
        #expect(patch.category == "MENTAL_HEALTH")
        #expect(patch.treatmentClass == "GLP1")
    }

    // MARK: - Helpers

    private static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
