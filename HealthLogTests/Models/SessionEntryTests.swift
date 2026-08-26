// Parity 2.2 — `GET /api/auth/me/sessions` decode + row-formatting contract.
//
// The session row is the one surface where a formatting slip is a security
// problem rather than a cosmetic one: a row that silently drops its location /
// masked-IP line, or that labels a never-used session "last active", tells the
// user something false about who is holding their account. These tests pin the
// decode tolerance and the pure row derivations without standing up the view.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Session list decode + row formatting (parity 2.2)")
    struct SessionEntryTests {
        private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try JSONDecoder.hlDefault.decode(type, from: Data(json.utf8))
        }

        // MARK: - Decode tolerance

        @Test("Full server row decodes every field")
        func decodesFullRow() throws {
            let entry = try decode(SessionEntry.self, """
            {
              "id": "sess_1",
              "device": "Safari on macOS",
              "ipMasked": "203.0.113.x",
              "location": "Berlin, DE",
              "lastActiveAt": "2026-07-18T10:00:00Z",
              "createdAt": "2026-07-01T08:00:00Z",
              "isCurrent": true
            }
            """)
            #expect(entry.id == "sess_1")
            #expect(entry.device == "Safari on macOS")
            #expect(entry.ipMasked == "203.0.113.x")
            #expect(entry.location == "Berlin, DE")
            #expect(entry.isCurrent)
            #expect(entry.lastActiveAt != nil)
        }

        @Test("Nullable server fields decode to nil rather than throwing")
        func decodesNullables() throws {
            let entry = try decode(SessionEntry.self, """
            {
              "id": "sess_2",
              "device": "Firefox on Windows",
              "ipMasked": null,
              "location": null,
              "lastActiveAt": null,
              "createdAt": "2026-07-01T08:00:00Z",
              "isCurrent": false
            }
            """)
            #expect(entry.ipMasked == nil)
            #expect(entry.location == nil)
            #expect(entry.lastActiveAt == nil)
        }

        @Test("A row missing isCurrent defaults to false, never to a bogus current marker")
        func missingIsCurrentDefaultsFalse() throws {
            let entry = try decode(SessionEntry.self, """
            { "id": "sess_3", "device": "Chrome", "createdAt": "2026-07-01T08:00:00Z" }
            """)
            #expect(!entry.isCurrent)
        }

        @Test("An absent sessions key decodes as an empty list, not a throw")
        func emptyEnvelopeDecodes() throws {
            let response = try decode(SessionListResponse.self, "{}")
            #expect(response.sessions.isEmpty)
        }

        @Test("The revoke-others response decodes its count")
        func revokeOthersDecodes() throws {
            let response = try decode(SessionRevokeOthersResponse.self, #"{"sessionsRevoked": 3}"#)
            #expect(response.sessionsRevoked == 3)
        }

        // MARK: - locationLine

        @Test("Location and masked IP join with location first, matching the web card")
        func locationLineJoinsBoth() {
            let entry = SessionEntry(
                id: "s", device: "Safari", ipMasked: "203.0.113.x",
                location: "Berlin, DE", createdAt: .now
            )
            #expect(entry.locationLine == "Berlin, DE · 203.0.113.x")
        }

        @Test("Only one of location / masked IP present yields that value alone, with no stray separator")
        func locationLineHandlesSingleValue() {
            let ipOnly = SessionEntry(id: "s", device: "Safari", ipMasked: "203.0.113.x", createdAt: .now)
            #expect(ipOnly.locationLine == "203.0.113.x")

            let locationOnly = SessionEntry(id: "s", device: "Safari", location: "Berlin, DE", createdAt: .now)
            #expect(locationOnly.locationLine == "Berlin, DE")
        }

        @Test("Neither value present yields nil so the row omits the line entirely")
        func locationLineNilWhenEmpty() {
            let entry = SessionEntry(id: "s", device: "Safari", createdAt: .now)
            #expect(entry.locationLine == nil)
        }

        @Test("Whitespace-only server values are treated as absent, not painted as a blank line")
        func locationLineIgnoresBlankStrings() {
            let entry = SessionEntry(
                id: "s", device: "Safari", ipMasked: "   ", location: "", createdAt: .now
            )
            #expect(entry.locationLine == nil)
        }

        // MARK: - Activity stamp

        @Test("lastActiveAt drives the stamp and marks the row as having real activity")
        func activityPrefersLastActive() {
            let created = Date(timeIntervalSince1970: 1_000_000)
            let active = Date(timeIntervalSince1970: 2_000_000)
            let entry = SessionEntry(
                id: "s", device: "Safari", lastActiveAt: active,
                createdAt: created, isCurrent: false
            )
            #expect(entry.effectiveActivityDate == active)
            #expect(entry.hasRecordedActivity)
        }

        @Test("Without lastActiveAt the row falls back to createdAt and reports no recorded activity")
        func activityFallsBackToCreatedAt() {
            let created = Date(timeIntervalSince1970: 1_000_000)
            let entry = SessionEntry(id: "s", device: "Safari", createdAt: created)
            #expect(entry.effectiveActivityDate == created)
            // Load-bearing: this is what stops the row saying "last active" about
            // a session that has never been used.
            #expect(!entry.hasRecordedActivity)
        }
    }

#endif
