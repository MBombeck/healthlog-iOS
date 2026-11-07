import Foundation
@testable import HealthLog

/// **AUDITC (1.5.0)** — the AUDIT-C half of ``LifeServerStub``, modelled on
/// `src/app/api/anamnesis/audit-c/route.ts` of server v1.47.0: a `locale`
/// other than the offered one is 422, a `takenAt` more than five minutes ahead
/// is 422, a repeated `externalId` answers 200 with the stored result, and
/// the read block names the newest readable entry. The wording is invented
/// on purpose: the app must render whatever the server sends.
///
/// Called by ``LifeServerStub`` under its lock, which guards this state too.
final class AuditCServerStub: @unchecked Sendable {
    struct Entry {
        let id: String
        let takenAt: String
        let items: [Int]
        let locale: String
        let externalId: String?
        var readable = true
    }

    /// The wording the account is offered (`auditC.instrument.locale`).
    var offeredLocale = "de"
    var validatedLocale = true
    /// The profile's sex; `nil` gives no cut-off.
    var sex: String? = "female"
    var entries: [Entry] = []
    /// The server clock the five-minute rule is measured against.
    var now = Date()
    private var counter = 0

    static let stems = ["Stem one, as delivered", "Stem two, as delivered", "Stem three, as delivered"]

    func route(method: String, path: String, body: [String: Any]) -> (Int, String)? {
        let base = "/api/anamnesis/audit-c"
        if method == "POST", path == base { return create(body) }
        if method == "DELETE", path.hasPrefix(base + "/") {
            let id = String(path.dropFirst(base.count + 1))
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                return (404, #"{"data":null,"error":"not found","meta":{"errorCode":"anamnesis.auditC.notFound"}}"#)
            }
            entries.remove(at: index)
            return (200, LifeCircumstancesFixtures.envelope(#"{"id":"\#(id)","removedAt":"2026-11-05T09:00:00.000Z"}"#))
        }
        return nil
    }

    private static let invalid = #"{"data":null,"error":"invalid","meta":{"errorCode":"anamnesis.auditC.invalid"}}"#

    private func create(_ body: [String: Any]) -> (Int, String) {
        guard let items = body["items"] as? [Int], items.count == 3, items.allSatisfy({ (0 ... 4).contains($0) }),
              body["source"] as? String == "IOS" else { return (422, Self.invalid) }
        if let locale = body["locale"] as? String, locale != offeredLocale { return (422, Self.invalid) }
        let stamp = body["takenAt"] as? String
        if let stamp, let date = ISO8601DateFormatter.fractional.date(from: stamp),
           date > now.addingTimeInterval(5 * 60)
        {
            return (422, Self.invalid)
        }
        let externalId = body["externalId"] as? String
        if let externalId, let stored = entries.first(where: { $0.externalId == externalId }) {
            return (200, LifeCircumstancesFixtures.envelope(#"{"result":\#(result(stored))}"#))
        }
        counter += 1
        let entry = Entry(
            id: "audit-\(counter)",
            takenAt: stamp ?? "2026-11-05T09:00:00.000Z",
            items: items,
            locale: offeredLocale,
            externalId: externalId
        )
        entries.insert(entry, at: 0)
        return (201, LifeCircumstancesFixtures.envelope(#"{"result":\#(result(entry))}"#))
    }

    func result(_ entry: Entry) -> String {
        let total = entry.items.reduce(0, +)
        let german = entry.locale == "de"
        var cutoff = "null"
        var above = "null"
        if let sex {
            let value = german ? (sex == "male" ? 5 : 4) : (sex == "male" ? 4 : 3)
            let label = german ? "S3 guideline (Germany)" : "Bradley 2007 (United States)"
            let source = german ? "S3_ALCOHOL_DE" : "BRADLEY_2007"
            cutoff = #"{"value":\#(value),"sex":"\#(sex)","source":"\#(source)","sourceLabel":"\#(label)","sourceUrl":"https://example.org/\#(source)"}"#
            above = String(total >= value)
        }
        return #"{"id":"\#(entry.id)","takenAt":"\#(entry.takenAt)","items":\#(entry.items),"totalScore":\#(total),"#
            + #""locale":"\#(entry.locale)","cutoff":\#(cutoff),"aboveCutoff":\#(above),"validatedLocale":\#(validatedLocale)}"#
    }

    func json() -> String {
        let latest = entries.first(where: \.readable).map(result) ?? "null"
        let history = entries.map {
            #"{"id":"\#($0.id)","takenAt":"\#($0.takenAt)","totalScore":\#($0.items.reduce(0, +))}"#
        }.joined(separator: ",")
        let due = !entries.contains(where: \.readable)
        return #"{"latest":\#(latest),"history":[\#(history)],"offerDue":\#(due),"instrument":\#(instrument())}"#
    }

    private func instrument() -> String {
        let items = Self.stems.enumerated().map { index, stem in
            let options = (0 ... 4).map { #"{"value":\#($0),"label":"Answer \#(index + 1).\#($0)"}"# }
            return #"{"stem":"\#(stem)","options":[\#(options.joined(separator: ","))]}"#
        }.joined(separator: ",")
        return #"{"items":[\#(items)],"locale":"\#(offeredLocale)","validatedLocale":\#(validatedLocale),"#
            + #""standardDrink":"One drink, as delivered.","attribution":"WHO note, as delivered."}"#
    }
}
