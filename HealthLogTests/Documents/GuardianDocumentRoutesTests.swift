import Foundation
@testable import HealthLog
import Testing

/// #182 A5 (server v1.48.0, #1403): the document vault on a managed
/// profile. Reads take READ on `documents`; every change, the AI reads and the
/// capability take the guardian (MANAGE on a managed profile); the source
/// integrations, the layout save and the purge are the owner's. The
/// `record-settings` family is the guardian's alone. The client refuses
/// locally what the server would refuse, before anything leaves the device.
@Suite("Documents: guardian routes on a managed profile")
struct GuardianDocumentRoutesTests {
    private func entry(level: String, kind: String, sections: String = "null", canWrite: Bool = true) throws -> AccountAccessEntry {
        let json = """
        {"accountId":"acc-1","username":"x","level":"\(level)","recordKind":"\(kind)","sections":\(sections),"canWrite":\(canWrite)}
        """
        return try JSONDecoder.hlDefault.decode(AccountAccessEntry.self, from: Data(json.utf8))
    }

    @Test(
        "The route table follows the server's declarations",
        arguments: [
            ("/api/documents/inbound", HTTPMethod.get, DocumentRouteAccess.Need.read),
            ("/api/documents/inbound", .post, .guardian),
            ("/api/documents/inbound/doc1", .get, .read),
            ("/api/documents/inbound/doc1", .patch, .guardian),
            ("/api/documents/inbound/doc1", .delete, .guardian),
            ("/api/documents/inbound/doc1/original", .get, .read),
            ("/api/documents/inbound/doc1/thumbnail", .get, .read),
            ("/api/documents/inbound/doc1/summary", .get, .guardian),
            ("/api/documents/inbound/doc1/chat", .post, .guardian),
            ("/api/documents/inbound/doc1/facts/f1", .patch, .guardian),
            ("/api/documents/inbound/doc1/confirm", .post, .guardian),
            ("/api/documents/inbound/doc1/restore", .post, .guardian),
            ("/api/documents/inbound/doc1/purge", .delete, .ownerOnly),
            ("/api/documents/inbound/bulk", .post, .guardian),
            ("/api/documents/inbound/capability", .get, .guardian),
            ("/api/documents/inbound/deleted", .get, .guardian),
            ("/api/documents/inbound/reindex", .post, .guardian),
            ("/api/documents/inbound/usage", .get, .read),
            ("/api/documents/inbound/layout", .get, .read),
            ("/api/documents/inbound/layout", .put, .ownerOnly),
            ("/api/documents/inbound/source", .post, .ownerOnly),
            ("/api/documents/sources", .get, .ownerOnly),
            ("/api/documents/sources/paperless/import", .post, .ownerOnly)
        ]
    )
    func routeTable(path: String, method: HTTPMethod, expected: DocumentRouteAccess.Need) {
        #expect(DocumentRouteAccess.need(path: path, method: method) == expected)
    }

    @Test("Paths outside the vault are not document routes")
    func outsideVault() {
        #expect(DocumentRouteAccess.need(path: "/api/documentsX", method: .get) == nil)
        #expect(DocumentRouteAccess.need(path: "/api/labs", method: .get) == nil)
    }

    @Test("The client classifies the vault, record settings and the seizure diary")
    func clientClassification() {
        #expect(APIClient.recordRoute(for: "/api/documents/inbound", method: .get) == .section(.documents))
        #expect(APIClient.recordRoute(for: "/api/documents/inbound", method: .post) == .guardian(.documents))
        #expect(APIClient.recordRoute(for: "/api/documents/inbound/doc1/purge", method: .delete) == .unclassified)
        #expect(APIClient.recordRoute(for: "/api/record-settings/documents", method: .patch) == .guardianRecord)
        #expect(APIClient.recordRoute(for: "/api/seizures", method: .get) == .section(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/events", method: .post) == .section(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/events/e1", method: .patch) == .manage(.illness))
        // #191: a rescue dose on a seizure is WRITE like the seizure itself.
        #expect(APIClient.recordRoute(for: "/api/seizures/events/e1/rescue", method: .post) == .section(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/events/e1/rescue/d1", method: .patch) == .manage(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/events/e1/rescue/d1", method: .delete) == .manage(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/events/e1", method: .delete) == .manage(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/settings", method: .patch) == .manage(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/types", method: .get) == .section(.illness))
        #expect(APIClient.recordRoute(for: "/api/seizures/types", method: .post) == .manage(.illness))
        #expect(APIClient.recordRoute(for: "/api/settings/module-list-layout", method: .get) == .actor)
    }

    @Test("Only MANAGE on a managed profile is a guardian; an adult's MANAGE delegate is not")
    func guardianPredicate() throws {
        let guardian = try entry(level: "manage", kind: "managed")
        #expect(guardian.isGuardianOfManagedProfile)
        #expect(guardian.allowsGuardian(section: .documents))
        let adultManage = try entry(level: "manage", kind: "shared")
        #expect(!adultManage.isGuardianOfManagedProfile)
        #expect(!adultManage.allowsGuardian(section: .documents))
        let writer = try entry(level: "write", kind: "managed")
        #expect(!writer.isGuardianOfManagedProfile)
        let scoped = try entry(level: "manage", kind: "managed", sections: #"["labs"]"#)
        #expect(scoped.isGuardianOfManagedProfile)
        #expect(!scoped.allowsGuardian(section: .documents), "the section still has to be granted")
    }

    @Test("The reading switch is offered only to the guardian of a managed profile")
    func switchOffered() throws {
        let guardian = try entry(level: "manage", kind: "managed")
        let access = AccountAccess(accounts: [guardian], active: guardian, recordKind: .managed, canSwitch: true)
        #expect(ManagedProfileContext.isGuardian(access))
        #expect(!ManagedProfileContext.isGuardian(.ownerOnly))
        let reader = try entry(level: "read", kind: "shared", canWrite: false)
        let shared = AccountAccess(accounts: [reader], active: reader, recordKind: .shared, canSwitch: true)
        #expect(!ManagedProfileContext.isGuardian(shared))
    }

    @Test("record-settings documents decodes the standard envelope; autoAiRead defaults off")
    func settingsDecode() throws {
        let json = #"{"recordId":"rec_1","family":"documents","settings":{"autoAiRead":true}}"#
        let decoded = try JSONDecoder.hlDefault.decode(RecordSettingsRepository.Envelope.self, from: Data(json.utf8))
        #expect(decoded.settings.autoAiRead)
        let bare = try JSONDecoder.hlDefault.decode(RecordSettingsRepository.Envelope.self, from: Data(#"{"settings":{}}"#.utf8))
        #expect(!bare.settings.autoAiRead)
    }
}
