import Foundation
@testable import HealthLog
import Testing

/// **Audit v0162 — logout PHI-wipe failures are surfaced, not swallowed.**
///
/// The account-deletion / server-switch cascade wipes three at-rest PHI /
/// secret surfaces: the local-only GLP-1 store, the standalone offline mirror,
/// and the outbox AES-GCM cipher key. Those used to be silent `try?` swallows —
/// a wipe that genuinely failed would leave previous-user PHI (or a reusable
/// cipher key) on a shared device with nobody the wiser.
///
/// This is a source-level guard (same shape as the OutboxStore file-protection
/// guard): a failed wipe is not cheaply observable from a headless unit test, so
/// we pin the source so a drift back to the silent-`try?` shape breaks here. The
/// wipe LOGIC is unchanged — only the error handling is surfaced.
@MainActor
@Suite("Logout wipe-failure surfacing")
struct LogoutWipeFailureSurfacingTests {
    private func logoutSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Stores
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        return try String(
            contentsOf: root.appendingPathComponent("HealthLog/Stores/AppContainer+Logout.swift"),
            encoding: .utf8
        )
    }

    @Test("GLP-1 local-repo wipe failure is logged, not swallowed")
    func glp1WipeIsObservable() throws {
        let text = try logoutSource()
        #expect(!text.contains("try? await glp1LocalRepo.deleteAll()"))
        #expect(text.contains("try await glp1LocalRepo.deleteAll()"))
    }

    @Test("standalone-mirror wipe failure is logged, not swallowed")
    func standaloneMirrorWipeIsObservable() throws {
        let text = try logoutSource()
        #expect(!text.contains("try? await localRepo.deleteAll()"))
        #expect(text.contains("try await localRepo.deleteAll()"))
    }

    @Test("outbox cipher-key wipe failure is logged, not swallowed")
    func outboxKeyWipeIsObservable() throws {
        let text = try logoutSource()
        #expect(!text.contains("try? keychain.remove(forKey: KeychainKey.outboxPayloadKey)"))
        #expect(text.contains("try keychain.remove(forKey: KeychainKey.outboxPayloadKey)"))
    }

    @Test("the surfaced failures route through the sanitised logger")
    func wipeFailuresRouteThroughLogger() throws {
        let text = try logoutSource()
        // Each surfaced wipe logs via HLLog + sanitises the error (no raw PHI).
        #expect(text.contains("HLLog.storage.error("))
        #expect(text.contains("HLLog.security.error("))
        #expect(text.contains("LogSanitizer.redact(String(describing: error))"))
    }
}
