import Foundation
@testable import HealthLog
import Testing

/// **#115 B6 — a section word this build does not know is ignored.**
///
/// `sections` is a server vocabulary (`measurements`, `labs`, …) that grows
/// with the server. In 279 one unknown word made the whole grant
/// `.unavailable`, so a delegate lost every section the moment the server added
/// one. The orchestrator's decision: unknown words are ignored (not shown),
/// the known sections stay usable, and nothing becomes more visible — no
/// whole-record access, no route for the unknown word. A malformed grant
/// (not a list of strings, a repeated word, missing) stays refused.
@Suite("#115 B6 — unknown access sections are ignored, known ones stay")
struct AccountAccessUnknownSectionTests {
    private func entry(sections: String) throws -> AccountAccessEntry {
        let json = """
        {"accountId":"acc-1","username":"delegate","access":"read","level":"read",
         "recordKind":"shared","sections":\(sections),"canWrite":false}
        """
        return try JSONDecoder.hlDefault.decode(AccountAccessEntry.self, from: Data(json.utf8))
    }

    @Test("unknown next to known: the known section stays visible, the unknown one is not")
    func unknownBesideKnownKeepsKnown() throws {
        let access = try entry(sections: #"["measurements","vaccinations_v2","labs"]"#)
        #expect(access.sections == .subset([.measurements, .labs]))
        #expect(access.level == .read)
        #expect(access.allows(section: .measurements, write: false))
        #expect(access.allows(section: .labs, write: false))
        #expect(access.allows(section: .measurements, write: true) == false)
        // Nothing widens: no other section, no whole-record route.
        #expect(access.allows(section: .cycle, write: false) == false)
        #expect(access.allowsWholeRecord(write: false) == false)
    }

    @Test("only unknown words: an empty grant, not a refused one")
    func onlyUnknownIsEmptyNotRefused() throws {
        let access = try entry(sections: #"["vaccinations_v2"]"#)
        #expect(access.sections == .none)
        #expect(access.level == .read)
        #expect(access.recordKind == .shared)
        #expect(access.allows(section: .measurements, write: false) == false)
        #expect(access.allowsWholeRecord(write: false) == false)
    }

    @Test("malformed grants stay refused")
    func malformedStaysRefused() throws {
        #expect(try entry(sections: #"["measurements","measurements"]"#).sections == .unavailable)
        #expect(try entry(sections: #"["measurements",7]"#).sections == .unavailable)
        #expect(try entry(sections: #""measurements""#).sections == .unavailable)
    }

    @Test("the account can still be selected for its known sections")
    func selectableWithUnknownSection() async throws {
        let access = try entry(sections: #"["measurements","vaccinations_v2"]"#)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        await api.selectAccount(access)
        #expect(await api.selectedAccountID() == "acc-1")
    }
}
