// This suite hangs off `WidgetSnapshotWriter` (App-target only) — in the SPM
// library build there is no such type, so the file is skipped there.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// **W-PHI-HARDENING (reliability audit H4) — the logout widget reset must
    /// clear the at-rest snapshot PHI and SURFACE a write failure instead of
    /// silently swallowing it.**
    ///
    /// The App-Group snapshot is the only at-rest widget PHI (med name +
    /// next-dose time + today's mood + score + latest reading). On a shared
    /// device a failed clear leaves the PREVIOUS user's medical data rendered on
    /// the Home / Lock-Screen widgets for whoever signs in next. Pre-hardening
    /// the clear was a silent `try?`; now it `throws` so the logout cascade logs
    /// it, and reloads every timeline regardless of the write outcome.
    @MainActor
    @Suite("WidgetSnapshotWriter.reset — H4 shared-device PHI clear")
    struct WidgetSnapshotWriterResetTests {
        private var now: Date {
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 6
            comps.day = 16
            comps.hour = 9
            comps.minute = 0
            return Calendar.current.date(from: comps)!
        }

        /// Seed a snapshot carrying previous-user PHI, then `reset()` and assert
        /// the on-disk snapshot is the neutral placeholder — no med name, no
        /// dose, no mood/score/measurement glance survives.
        @Test("reset() clears the at-rest snapshot PHI to the placeholder")
        func resetClearsSnapshotToPlaceholder() async throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phi-reset-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = WidgetSnapshotStore(url: url)
            // Previous user's PHI sitting in the App-Group container.
            try store.write(WidgetSnapshot(
                nextDose: .init(
                    medicationId: "med-prev",
                    medicationName: "Sertraline",
                    doseText: "50 mg",
                    scheduledAt: now
                ),
                compliance: .init(scheduled: 3, taken: 2, serverCompliancePercent: 66),
                recentMood: .init(score: 2, loggedAt: now),
                healthScore: .init(score: 41, band: "red", resolvedAt: now),
                latestMeasurement: .init(
                    kindRaw: "bloodPressure", title: "Blood pressure",
                    formattedValue: "150/95", unit: "mmHg",
                    symbol: "heart.fill", recordedAt: now
                ),
                generatedAt: now
            ))
            #expect(store.read()?.nextDose?.medicationName == "Sertraline")

            let writer = WidgetSnapshotWriter(store: store)
            try await writer.reset()

            let cleared = try #require(store.read())
            #expect(cleared == .placeholder)
            #expect(cleared.nextDose == nil)
            #expect(cleared.recentMood == nil)
            #expect(cleared.healthScore == nil)
            #expect(cleared.latestMeasurement == nil)
            #expect(cleared.compliance.scheduled == 0)
            #expect(cleared.compliance.taken == 0)
        }

        /// **The de-silencing proof.** When the App-Group write genuinely can't
        /// complete (here: a URL whose parent directory does not exist), the old
        /// `try?`-wrapped reset passed silently and the previous user's PHI
        /// lingered. The hardened `reset()` now PROPAGATES the failure so the
        /// logout path knows about it (logs it, no PHI) — this test fails if
        /// anyone re-silences the write.
        @Test("reset() surfaces (throws) a write failure instead of swallowing it")
        func resetSurfacesWriteFailure() async {
            // Parent directory intentionally absent → `Data.write` throws.
            let unwritable = FileManager.default.temporaryDirectory
                .appendingPathComponent("phi-missing-dir-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("snapshot.json")
            let store = WidgetSnapshotStore(url: unwritable)
            let writer = WidgetSnapshotWriter(store: store)

            await #expect(throws: (any Error).self) {
                try await writer.reset()
            }
        }

        /// A `nil` App-Group container URL is a safe no-op (the store short-
        /// circuits before touching disk), so `reset()` must NOT throw on a
        /// device where the container is unavailable — the logout cascade still
        /// proceeds. (The reload fires via the `defer` either way.)
        @Test("reset() does not throw when the container URL is nil (safe no-op)")
        func resetIsSafeWithoutContainer() async throws {
            let writer = WidgetSnapshotWriter(store: WidgetSnapshotStore(url: nil))
            try await writer.reset() // must not throw
        }

        // MARK: - Phase 09 / plan 09-03 — the account boundary

        /// **What logout has to guarantee once widget writes are asynchronous.**
        ///
        /// The snapshot is the only at-rest widget PHI, so the clear is a hard
        /// shared-device invariant — and an invariant that holds only while every
        /// caller is synchronous is not an invariant, it is a coincidence. Moving
        /// the write off the main actor makes the coincidence unavailable, so the
        /// writer has to own the boundary explicitly: `reset()` closes admission
        /// and retires the account epoch before it drains, and it stays closed
        /// until the next authenticated composition re-opens it.
        ///
        /// The case reads the file after each step rather than trusting the API,
        /// because "no write happened" and "a write happened and was overwritten"
        /// are the same outcome from the caller's side.
        @Test("logout awaits the widget tail and rejects the previous account's epoch")
        func logoutAwaitsTailAndRejectsOldEpoch() async throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phi-epoch-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = WidgetSnapshotStore(url: url)
            let writer = WidgetSnapshotWriter(store: store)

            let previousUser = WidgetSnapshot.RecentMood(score: 2, loggedAt: now)
            let nextUser = WidgetSnapshot.RecentMood(score: 5, loggedAt: now.addingTimeInterval(3600))

            // The signed-in account's own update, enqueued before the teardown.
            writer.refreshMood(recentMood: previousUser, now: now)
            try await writer.reset()
            #expect(store.read() == .placeholder, "reset must not return before the placeholder is on disk")

            // A callback belonging to the signed-out account. It must be refused
            // — admission is closed until the next authenticated composition.
            writer.refreshMood(recentMood: previousUser, now: now.addingTimeInterval(60))
            await writer.drainPendingWrites()
            let afterLateCallback = try #require(store.read())
            let placeholderSurvived = afterLateCallback == .placeholder
            #expect(
                placeholderSurvived,
                "EXPECTED_RED: logout completed before widget tail reset"
            )

            // …and the next account is served normally.
            writer.admitNextAccount()
            writer.refreshMood(recentMood: nextUser, now: now.addingTimeInterval(120))
            await writer.drainPendingWrites()
            #expect(store.read()?.recentMood == nextUser)
        }
    }

#endif // !SWIFT_PACKAGE
