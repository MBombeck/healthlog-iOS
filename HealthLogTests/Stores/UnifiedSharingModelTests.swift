import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Wire fixtures for the unified sharing model. Deliberately **outside** the
/// `@MainActor` suite so the `@Sendable` `MockURLProtocol` handler can build
/// responses without hopping actors. The leaf ids here are a TEST vocabulary;
/// production never carries a list like this — it reads
/// `capabilities.share.leaves`.
private enum UnifiedFixtures {
    static let leaves = ["WEIGHT", "PULSE", "LAB_RESULTS", "MEDICATION_LIST", "MOOD", "INSURANCE"]
    static let groups = ["vitals", "labs", "medications", "sensitive"]

    static func capabilitiesJSON(leaves: [String] = UnifiedFixtures.leaves) -> String {
        let leafList = leaves.map { "\"\($0)\"" }.joined(separator: ",")
        let groupList = groups.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"apiContractVersion":"1.34.2",
         "share":{"supported":true,"maxDays":90,"reportDownload":["fhir","pdf"],
                  "selectionVersion":2,
                  "groups":[\(groupList)],"leaves":[\(leafList)]}}
        """
    }

    static func profileJSON(
        leaves: [String],
        format: String = "pdf",
        rangeDays: Int = 180,
        includeCharts: Bool = false
    ) -> String {
        let leafList = leaves.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"profile":{"v":2,"leaves":[\(leafList)],"format":"\(format)",
                    "rangeDays":\(rangeDays),"includeCharts":\(includeCharts)}}
        """
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
    static func body(of req: URLRequest) -> Data {
        req.httpBody ?? req.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: size)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data
        } ?? Data()
    }

    static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        let http = HTTPURLResponse(
            url: req.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (http, Data(json.utf8))
    }
}

/// Captures the last `PUT /api/auth/me/report-selection` body so the round-trip
/// can be asserted on the wire rather than on the store's own state.
private final class BodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func set(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        value = data
    }

    var captured: Data? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// **Phase 18 / 18-01 — the one sharing surface's model (D2, D3 per E1).**
///
/// Four claims, one per question the consolidation has to answer:
///   1. the surface asks exactly *what* and *for which period*, and puts the
///      output form LAST (E1.1),
///   2. the default selection is EMPTY and "Alles auswählen" is an explicit act
///      (E1.2 — the operator's answered decision, chosen AGAINST the
///      walkthrough's literal "standardmäßig alles"),
///   3. the selection state IS the saved report-selection profile, so the FHIR
///      export's silent inheritance becomes the visible, shared choice,
///   4. period and link expiry are distinct concepts and never share a field.
///
/// Drives the real `ServerCapabilitiesRepository` / `ReportSelectionRepository`
/// over the real `APIClient` with a stubbed `URLSession` (`MockURLProtocol`) —
/// never a mock server (PROJECT_GUIDE.md). `.serialized` because the handler is
/// process-global.
@Suite("UnifiedSharingModel", .serialized)
@MainActor
struct UnifiedSharingModelTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeStore(
        _ api: APIClient,
        form: UnifiedSharingStore.OutputForm = .link,
        now: @escaping () -> Date = { .now }
    ) -> UnifiedSharingStore {
        UnifiedSharingStore(
            profile: ReportSelectionStore(
                capabilities: ServerCapabilitiesRepository(api: api),
                profiles: ReportSelectionRepository(api: api)
            ),
            form: form,
            now: now
        )
    }

    // MARK: - 1. Two questions, then the form

    @Test("Die Fläche stellt genau zwei Fragen — was und für welchen Zeitraum — und die Ausgabeform zuletzt")
    func twoQuestionsThenForm() {
        var violations: [String] = []

        let order = UnifiedSharingStore.questionOrder
        if order != [.what, .period, .form] {
            violations.append("question order is \(order.map(\.rawValue))")
        }
        if Set(order) != Set(UnifiedSharingStore.Question.allCases) {
            violations.append("the order does not cover the whole question set")
        }
        if order.last != .form {
            violations.append("the output form is not the last question")
        }
        // The four outputs are siblings of ONE flow, not four flows.
        if Set(UnifiedSharingStore.OutputForm.allCases) != [.link, .pdf, .zip, .fhir] {
            violations.append("output forms are \(UnifiedSharingStore.OutputForm.allCases.map(\.rawValue))")
        }
        // The period vocabulary is the intersection every surface can serve.
        if UnifiedSharingStore.periodOptions != [30, 90, 180, 365] {
            violations.append("period options are \(UnifiedSharingStore.periodOptions)")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: no unified sharing model exists

            E1.1. D2's complaint was four surfaces asking overlapping questions and \
            answering them differently. One model, two questions, the form last. Offen: \(violations)
            """
        )
    }

    // MARK: - 2. The empty default, and select-all as an act

    @Test("Leere Vorauswahl bleibt — „Alles auswählen“ ist ein Tap, kein Zustand")
    func emptyDefaultWithSelectAll() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return UnifiedFixtures.ok(req, UnifiedFixtures.capabilitiesJSON())
            }
            return UnifiedFixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI(), form: .pdf)
        var violations: [String] = []

        // The default, before anything is loaded and after a load that found no
        // saved profile. Both are the operator's answered decision (E1.2).
        if !store.chosen.isEmpty {
            violations.append("a fresh model preselected \(store.chosen.sorted())")
        }
        if UnifiedSharingStore.defaultSelection != .empty {
            violations.append("defaultSelection is \(UnifiedSharingStore.defaultSelection.leaves)")
        }
        await store.load()
        if !store.chosen.isEmpty {
            violations.append("a load with no saved profile preselected \(store.chosen.sorted())")
        }

        store.selectAll()
        if store.chosen != Set(store.offeredLeaves) {
            violations.append("select-all left \(store.chosen.sorted()) of \(store.offeredLeaves)")
        }
        if store.offeredLeaves.isEmpty {
            violations.append("nothing was offered to select at all")
        }

        store.clearSelection()
        if !store.chosen.isEmpty {
            violations.append("clear left \(store.chosen.sorted())")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: no one-tap select-all over an empty default exists

            E1.2 (.planning/active/v1-readiness/DECISIONS.md, 2026-08-22). The operator's \
            walkthrough sentence asked for "standardmäßig alles"; shown that this inverts the \
            privacy meaning of an empty selection, he chose the EMPTY default plus an explicit \
            button. If this case ever fails because the default became non-empty, that is the \
            regression — read DECISIONS.md before "fixing" it. Offen: \(violations)
            """
        )
    }

    // MARK: - 3. The selection IS the profile

    @Test("Die Auswahl IST das gespeicherte Report-Profil — geladen und zurückgeschrieben")
    func selectionIsTheProfile() async {
        let captured = BodyBox()
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return UnifiedFixtures.ok(req, UnifiedFixtures.capabilitiesJSON())
            }
            if req.httpMethod == "PUT" {
                captured.set(UnifiedFixtures.body(of: req))
                return UnifiedFixtures.ok(
                    req,
                    UnifiedFixtures.profileJSON(leaves: ["PULSE", "LAB_RESULTS"], rangeDays: 30)
                )
            }
            return UnifiedFixtures.ok(req, UnifiedFixtures.profileJSON(leaves: ["PULSE", "MOOD"]))
        }

        let store = makeStore(makeAPI(), form: .pdf)
        let violations = await Self.roundTripViolations(store: store, captured: captured)

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the model does not round-trip the report-selection profile

            The four old surfaces already shared this profile without admitting it; the \
            unified model owns it in the open. Offen: \(violations)
            """
        )
    }

    /// Load → edit → save, reporting everything the round-trip got wrong.
    private static func roundTripViolations(store: UnifiedSharingStore, captured: BodyBox) async -> [String] {
        var violations: [String] = []
        await store.load()
        if store.chosen != ["PULSE", "MOOD"] {
            violations.append("load adopted \(store.chosen.sorted()) instead of the saved profile")
        }
        // The profile's presentation half is the model's period — one field, not two.
        if store.periodDays != 180 {
            violations.append("the saved rangeDays became periodDays \(store.periodDays)")
        }

        store.toggle("MOOD")
        store.toggle("LAB_RESULTS")
        store.periodDays = 30
        await store.save()

        guard let body = captured.captured else {
            return violations + ["no PUT reached /api/auth/me/report-selection"]
        }
        violations += putViolations(in: body)
        // The server's canonical echo is adopted, not the value we sent.
        if store.periodDays != 30 {
            violations.append("the echo was not adopted (periodDays \(store.periodDays))")
        }
        return violations
    }

    /// The five mandatory `.strict()` fields, as the route takes them.
    private static func putViolations(in body: Data) -> [String] {
        var violations: [String] = []
        let decoded = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let sent = decoded?["leaves"] as? [String] ?? []
        if Set(sent) != ["PULSE", "LAB_RESULTS"] {
            violations.append("the PUT carried \(sent)")
        }
        if decoded?["rangeDays"] as? Int != 30 {
            violations.append("the PUT carried rangeDays \(String(describing: decoded?["rangeDays"]))")
        }
        if decoded?["v"] as? Int != 2 {
            violations.append("the PUT carried v \(String(describing: decoded?["v"]))")
        }
        return violations
    }

    // MARK: - 4. Period is not expiry

    @Test("Zeitraum und Ablaufdatum sind zwei Begriffe und teilen sich kein Feld")
    func periodAndExpiryAreDistinct() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(makeAPI(), form: .link, now: { anchor })
        var violations: [String] = []

        let day = TimeInterval(86400)
        store.periodDays = 365
        store.expiresAt = anchor.addingTimeInterval(30 * day)
        if store.periodDays != 365 {
            violations.append("setting the expiry moved the period to \(store.periodDays)")
        }
        store.periodDays = 30
        if store.expiresAt != anchor.addingTimeInterval(30 * day) {
            violations.append("setting the period moved the expiry to \(String(describing: store.expiresAt))")
        }

        // Exactly the three rules `CreateShareLinkSheet` enforced.
        store.expiresAt = nil
        if store.validateExpiry() != [.missing] {
            violations.append("an absent expiry raised \(store.validateExpiry())")
        }
        store.expiresAt = anchor.addingTimeInterval(-day)
        if store.validateExpiry() != [.notInFuture] {
            violations.append("a past expiry raised \(store.validateExpiry())")
        }
        store.expiresAt = anchor.addingTimeInterval(91 * day)
        if store.validateExpiry() != [.tooFarAhead(maxDays: 90)] {
            violations.append("a 91-day expiry raised \(store.validateExpiry())")
        }
        store.expiresAt = anchor.addingTimeInterval(30 * day)
        if !store.validateExpiry().isEmpty {
            violations.append("a 30-day expiry raised \(store.validateExpiry())")
        }
        // The period is content, the expiry is the link's life — a 365-day
        // period on a 30-day link is legal and must stay legal.
        store.periodDays = 365
        if !store.validateExpiry().isEmpty {
            violations.append("a 365-day period made the 30-day expiry invalid")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: period and expiry are not yet modeled apart

            Period bounds WHAT the recipient sees; expiry bounds WHEN the link dies. \
            Conflating them is the one thing the unified surface must not do. Offen: \(violations)
            """
        )
    }
}
