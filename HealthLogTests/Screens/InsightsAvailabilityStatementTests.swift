// 22-01 (R4 / V1S-INSIGHTS) — the honesty half.
//
// R4-ANSWER row 6: the tab strip never had a skeleton, in any build. What it
// had was a short list and no statement — which reads exactly like a complete
// list. b266's silhouette and b267's silence are the two lies available; this
// pins the third answer, one quiet line, and pins just as hard that the line
// stays away as soon as the strip has anything real to show.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("InsightsAvailabilityStatementTests — der Streifen sagt, was er weiss (22-01)")
    struct InsightsAvailabilityStatementTests {
        @Test("Ohne eingerastete Kinds sagt der Streifen seinen Zustand")
        func unresolvedStripStatesItself() throws {
            try #require(
                InsightsAvailabilityStatement.statement(for: .pending, latchedKindsAreEmpty: true) == .loading,
                """
                EXPECTED_RED: while the availability read is still in flight and the strip knows no kind, \
                the strip region carries no statement at all — a short list that says nothing reads like \
                a complete one
                """
            )
            #expect(
                InsightsAvailabilityStatement.statement(for: .unresolved, latchedKindsAreEmpty: true)
                    == .unavailable,
                "a read that returned with nothing must say so instead of leaving sections silently absent"
            )
            // Every statement must resolve through the catalogue: `String(localized:)`
            // hands back the KEY when the entry is missing, so key-identity is the
            // witness that `de` + `en` actually landed.
            for statement in InsightsAvailabilityStatement.Statement.allCases {
                #expect(
                    statement.text != statement.rawValue,
                    "the catalogue must carry \(statement.rawValue) — otherwise the operator reads the key"
                )
            }
        }

        @Test("Pin: sobald etwas eingerastet oder aufgeloest ist, schweigt der Streifen")
        func resolvedOrLatchedStripStaysSilent() {
            #expect(
                InsightsAvailabilityStatement.text(for: .resolved, latchedKindsAreEmpty: false) == nil,
                "a resolved read needs no commentary"
            )
            #expect(
                InsightsAvailabilityStatement.text(for: .resolved, latchedKindsAreEmpty: true) == nil,
                """
                a read that PUBLISHED an empty answer is the empty-account case, not a failure — \
                22-02's accessibility gate caught what inferring otherwise costs
                """
            )
            #expect(
                InsightsAvailabilityStatement.text(for: .pending, latchedKindsAreEmpty: false) == nil,
                "the strip already shows kinds — a loading line over live pills would be noise"
            )
            #expect(
                InsightsAvailabilityStatement.text(for: .unresolved, latchedKindsAreEmpty: false) == nil,
                "the monotonic latch still holds kinds; the strip shows what it knows and says nothing"
            )
        }
    }

#endif
