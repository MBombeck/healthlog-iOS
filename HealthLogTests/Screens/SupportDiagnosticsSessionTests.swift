import Foundation
@testable import HealthLog
import Testing

/// The support session guards the APNs token fragments and the deep sync
/// detail; it must open only through a stated two-step and fall back to
/// locked whenever it ends.
@Suite("Support diagnostics session")
struct SupportDiagnosticsSessionTests {
    @Test("a fresh session is locked and a bare confirm does not open it")
    func confirmWithoutRequestStaysLocked() {
        var session = SupportDiagnosticsSession()
        #expect(!session.isConfirmed)
        #expect(!session.isAwaitingConfirmation)
        session.confirm()
        #expect(!session.isConfirmed, "confirm() must not skip the stated consequence")
    }

    @Test("request then confirm opens the session")
    func twoStepOpensTheSession() {
        var session = SupportDiagnosticsSession()
        session.requestConfirmation()
        #expect(session.isAwaitingConfirmation)
        #expect(!session.isConfirmed)
        session.confirm()
        #expect(session.isConfirmed)
        #expect(!session.isAwaitingConfirmation)
    }

    @Test("end returns an open session to locked, and a bare confirm cannot reopen it")
    func endLocksTheSession() {
        var session = SupportDiagnosticsSession()
        session.requestConfirmation()
        session.confirm()
        session.end()
        #expect(!session.isConfirmed)
        #expect(!session.isAwaitingConfirmation)
        session.confirm()
        #expect(!session.isConfirmed)
    }

    @Test("a cancelled confirmation is a full reset")
    func cancelledConfirmationResets() {
        var session = SupportDiagnosticsSession()
        session.requestConfirmation()
        session.end()
        session.confirm()
        #expect(!session.isConfirmed)
        #expect(session == SupportDiagnosticsSession())
    }

    @Test("every new session starts identical and locked")
    func newSessionsAreLocked() {
        #expect(SupportDiagnosticsSession() == SupportDiagnosticsSession())
        #expect(!SupportDiagnosticsSession().isConfirmed)
    }
}

/// Support detail shows only shortened identifiers, never the whole value.
@Suite("Support diagnostics redaction")
struct SupportDiagnosticsRedactionTests {
    @Test("absent and empty values stay absent")
    func absentStaysAbsent() {
        #expect(SupportDiagnosticsRedaction.fragment(nil) == nil)
        #expect(SupportDiagnosticsRedaction.fragment("") == nil)
        #expect(SupportDiagnosticsRedaction.tail(nil) == nil)
        #expect(SupportDiagnosticsRedaction.tail("") == nil)
    }

    @Test("a value no longer than the kept length passes unchanged")
    func shortValuePassesThrough() {
        #expect(SupportDiagnosticsRedaction.fragment("abcd", keeping: 8) == "abcd")
        #expect(SupportDiagnosticsRedaction.tail("abcd", keeping: 8) == "abcd")
    }

    @Test("a long value keeps only its head or tail")
    func longValueIsShortened() throws {
        let long = "0123456789abcdef"
        let head = try #require(SupportDiagnosticsRedaction.fragment(long, keeping: 8))
        #expect(head == "01234567" + SupportDiagnosticsRedaction.elision)
        #expect(!head.contains("abcdef"))
        let tail = try #require(SupportDiagnosticsRedaction.tail(long, keeping: 8))
        #expect(tail == SupportDiagnosticsRedaction.elision + "89abcdef")
        #expect(!tail.contains("01234567"))
    }

    @Test("keeping nothing yields only the elision")
    func keepingZeroYieldsElision() {
        #expect(SupportDiagnosticsRedaction.fragment("secret", keeping: 0) == SupportDiagnosticsRedaction.elision)
        #expect(SupportDiagnosticsRedaction.tail("secret", keeping: 0) == SupportDiagnosticsRedaction.elision)
    }
}
