import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The red actions in Settings that end access without deleting an entry
/// ride the delete ladder: they ask first, cannot be swiped through, answer
/// with their own word instead of "Delete", and run the revoke exactly once.
@MainActor
@Suite("Settings revoke on the delete ladder")
struct N2SettingsRevokeLadderTests {
    @MainActor
    private final class Log {
        var revokes = 0
    }

    private struct Case {
        let name: String
        let make: (@escaping @MainActor () async -> Void) -> HLDeleteAction
        let title: LocalizedStringKey
        let message: LocalizedStringKey
        let word: LocalizedStringKey
    }

    private static let cases: [Case] = [
        Case(
            name: "session",
            make: { SettingsRevokeAction.session(perform: $0) },
            title: "sessions.revoke.confirmTitle",
            message: "sessions.revoke.confirmBody",
            word: "sessions.revoke.confirmAction"
        ),
        Case(
            name: "connection",
            make: { SettingsRevokeAction.connection(perform: $0) },
            title: "Disconnect this assistant?",
            message: "It loses access to your health record immediately, including any refresh it holds. You can connect it again later.",
            word: "Disconnect"
        ),
        Case(
            name: "token",
            make: { SettingsRevokeAction.token(perform: $0) },
            title: "Revoke this token?",
            message: "Anything using this token stops working immediately. This can't be undone.",
            word: "Revoke token"
        ),
        Case(
            name: "share link",
            make: { SettingsRevokeAction.shareLink(perform: $0) },
            title: "Revoke this share link?",
            message: "The doctor will lose access immediately. This can't be undone.",
            word: "Revoke link"
        )
    ]

    @Test("every revoke asks first and cannot be swiped through")
    func asksFirst() {
        for item in Self.cases {
            let action = item.make {}
            #expect(action.requiresConfirmation, "\(item.name)")
            #expect(!action.allowsFullSwipe, "\(item.name)")
        }
    }

    @Test("every revoke keeps the question and answers with its own word, never Delete")
    func ownWord() {
        for item in Self.cases {
            let action = item.make {}
            #expect(action.question?.title == Text(item.title), "\(item.name)")
            #expect(action.question?.message == Text(item.message), "\(item.name)")
            #expect(action.word == item.word, "\(item.name)")
            #expect(action.word != HLControlWord.delete.key, "\(item.name)")
            #expect(action.symbol == SettingsRevokeAction.symbol, "\(item.name)")
            #expect(action.symbol != HLDeleteAction.deleteSymbol, "\(item.name)")
        }
    }

    @Test("the answer to the question revokes exactly once")
    func revokesOnce() async {
        for item in Self.cases {
            let log = Log()
            let runner = HLDeleteRunner()
            let action = item.make { log.revokes += 1 }
            runner.trigger(action)
            #expect(runner.isAsking, "\(item.name)")
            #expect(log.revokes == 0, "\(item.name): nothing runs before the answer")
            runner.confirm()
            for _ in 0 ..< 1000 where log.revokes == 0 || runner.isRunning {
                await Task.yield()
            }
            #expect(log.revokes == 1, "\(item.name)")
        }
    }

    @Test("the access-header error line keeps its identifier in Settings and onboarding")
    func accessHeaderErrorIdentifier() {
        #expect(ServerAccessHeadersEditor.errorIdentifier == "serverAccessHeaders.error")
    }
}
