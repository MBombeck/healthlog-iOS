import Foundation
@testable import HealthLog
import Testing

/// **audit-v0162 M-7 — the gate that was built and never wired.**
///
/// `MedicationsStore.derivedIntakeSynthesisEnabledProvider` shipped as
/// `= { true }` with an "until wired" note; only tests ever assigned it, so the
/// client synthesised placeholder doses on EVERY server — including the
/// slot-materialising ones, where a `scheduledFor` divergence beyond the ±5-min
/// dedup parks the placeholder next to the real row (inflated "N offen",
/// phantom overdue ring dose, inflated badge).
///
/// `MedicationsStoreDerivedIntakeGateTests` already pins the gate as a
/// *function*. What was missing — and what would have caught the bug — is the
/// wiring assertion at the bottom of this file: a modern server verdict must
/// actually reach the live store's provider through the composition root.
@Suite("audit-v0162 M-7 — slot-materialisation gate")
struct MedicationSlotMaterializationGateTests {
    // MARK: - Threshold

    /// v1.8.1 is the first server build whose today-projector fans out over
    /// every `timesOfDay` entry, so from there on the server answers with the
    /// FULL set of today's slots for every cadence. Verified against the server
    /// tree, not inherited from the (ledger-boundary) v1.15.17 PROJECT_GUIDE.md line.
    @Test(
        "threshold — a server materialises slots from v1.8.1 upward",
        arguments: [
            ("1.4.41", false),
            ("1.6.0", false),
            ("1.7.3", false),
            ("1.8.0", false),
            ("1.8.1", true),
            ("1.8.2", true),
            ("1.15.17", true),
            ("1.15.18", true),
            ("1.35.1", true),
            ("v1.35.1", true)
        ]
    )
    func thresholdVerdict(version: String, materialises: Bool) {
        let info = ServerVersionInfo(version: version)
        #expect(MedicationSlotMaterialization.isAvailable(on: info) == materialises)
    }

    /// Mirrors `TwoFactorManagement` / `WebHandoffLogin`: an unreadable running
    /// version is "not known ≥ target", i.e. the server is treated as one that
    /// does NOT materialise slots.
    @Test("threshold — an unparseable version fails closed")
    func unparseableVersionFailsClosed() {
        #expect(MedicationSlotMaterialization.isAvailable(on: ServerVersionInfo(version: "")) == false)
        #expect(MedicationSlotMaterialization.isAvailable(on: ServerVersionInfo(version: "unknown")) == false)
    }

    // MARK: - Gate semantics + persistence

    /// Each test gets its own scratch defaults suite so nothing touches
    /// `.standard` (and so the suite needs no process-wide serialisation).
    private func scratchDefaults() throws -> UserDefaults {
        let name = "hl.tests.slotgate.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("unknown verdict — synthesis stays OFF (do not invent a dose)")
    @MainActor
    func unknownVerdictDoesNotSynthesise() throws {
        let gate = try MedicationSlotMaterializationGate(defaults: scratchDefaults())
        #expect(gate.serverMaterializesSlots == nil)
        #expect(gate.synthesisEnabled == false, "an unprobed server must not produce phantom doses")
    }

    @Test("a modern server switches synthesis off; an ancient one switches it on")
    @MainActor
    func verdictDrivesSynthesis() throws {
        let gate = try MedicationSlotMaterializationGate(defaults: scratchDefaults())

        gate.apply(ServerVersionInfo(version: "1.35.1"))
        #expect(gate.serverMaterializesSlots == true)
        #expect(gate.synthesisEnabled == false)

        gate.apply(ServerVersionInfo(version: "1.7.3"))
        #expect(gate.serverMaterializesSlots == false)
        #expect(gate.synthesisEnabled == true, "a pre-1.8.1 server still needs the client fallback")
    }

    /// The whole point of persisting: the "not yet known" window is a
    /// once-per-installation event, not a once-per-cold-launch one.
    @Test("the verdict survives a cold start — the unknown window opens only once")
    @MainActor
    func verdictPersistsAcrossInstances() throws {
        let defaults = try scratchDefaults()
        MedicationSlotMaterializationGate(defaults: defaults)
            .apply(ServerVersionInfo(version: "1.35.1"))

        let afterRelaunch = MedicationSlotMaterializationGate(defaults: defaults)
        #expect(afterRelaunch.serverMaterializesSlots == true)
        #expect(afterRelaunch.synthesisEnabled == false, "a cold start must not re-open the unknown window")
    }

    @Test("forget() drops the verdict — a re-pointed app re-decides")
    @MainActor
    func forgetResetsToUnknown() throws {
        let defaults = try scratchDefaults()
        let gate = MedicationSlotMaterializationGate(defaults: defaults)
        gate.apply(ServerVersionInfo(version: "1.7.3"))
        #expect(gate.synthesisEnabled == true)

        gate.forget()
        #expect(gate.serverMaterializesSlots == nil)
        #expect(gate.synthesisEnabled == false)
        #expect(
            MedicationSlotMaterializationGate(defaults: defaults).serverMaterializesSlots == nil,
            "forget() must clear the persisted value too, not just the in-memory one"
        )
    }
}

// The wiring assertions need the App-Target composition root, which does not
// exist in the SPM-library build.
#if !SWIFT_PACKAGE

    /// **The missing test.** Everything above passes just as happily against an
    /// unwired `= { true }` provider — these do not.
    /// `.serialized` — `AppContainer` hardwires `UserDefaults.standard`, so the
    /// persisted verdict these tests write is process-wide state.
    @MainActor
    @Suite("audit-v0162 M-7 — the gate is actually WIRED", .serialized)
    struct MedicationSlotGateWiringTests {
        @Test("a modern server verdict switches the live store's synthesis OFF")
        func modernServerDisablesSynthesisOnTheLiveStore() {
            let container = makeContainer()
            container.medicationSlotGate.apply(ServerVersionInfo(version: "1.35.1"))

            #expect(
                container.medicationsStore.derivedIntakeSynthesisEnabledProvider() == false,
                """
                AppContainer must point MedicationsStore.derivedIntakeSynthesisEnabledProvider \
                at MedicationSlotMaterializationGate. It shipped as `= { true }` "until wired" \
                and was never connected — so every modern server kept getting client-synthesised \
                phantom doses next to its own rows.
                """
            )
        }

        @Test("the synthesised placeholders really disappear on a modern server")
        func modernServerLeavesNoPlaceholdersInTheDueSurface() {
            let container = makeContainer()
            let store = container.medicationsStore
            store._testForceSet(medications: [Self.twiceDaily()])
            store._testForceSet(todayIntakes: [Self.divergentServerDose()])

            // Unknown verdict (fresh install) — already no phantoms.
            #expect(store.derivedTodayIntakes.filter(\.isSynthesizedPlaceholder).isEmpty)

            container.medicationSlotGate.apply(ServerVersionInfo(version: "1.35.1"))
            let derived = store.derivedTodayIntakes
            #expect(derived.map(\.id) == ["server-divergent"], "only the server ledger's row survives")
        }

        @Test("a pre-1.8.1 server keeps the client fallback alive")
        func ancientServerKeepsSynthesis() {
            let container = makeContainer()
            let store = container.medicationsStore
            store._testForceSet(medications: [Self.twiceDaily()])
            store._testForceSet(todayIntakes: [])

            container.medicationSlotGate.apply(ServerVersionInfo(version: "1.7.3"))
            #expect(store.derivedIntakeSynthesisEnabledProvider() == true)
            #expect(
                store.derivedTodayIntakes.contains { $0.isSynthesizedPlaceholder },
                "a server that does not materialise slots must still get the fallback"
            )
        }

        /// A mid-session flip must not swallow a dose the operator already
        /// marked. The optimistic synth row lives in `todayIntakes` (appended by
        /// `markSynthesizedPlaceholderWithOutcome`) and may still be queued in
        /// the outbox; the gate-off branch filters by today's window only, so it
        /// stays painted until the server's own row replaces the array.
        @Test("an optimistic synth row survives the gate flipping off mid-session")
        func optimisticSynthRowSurvivesTheFlip() throws {
            let container = makeContainer()
            let store = container.medicationsStore
            let slot = try #require(
                Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date())
            )
            let optimistic = MedicationIntake(
                id: MedicationIntake.synthesizedPlaceholderID(medicationId: "med-lisinopril", scheduledAt: slot),
                medicationId: "med-lisinopril",
                scheduledAt: slot,
                takenAt: slot,
                status: .taken,
                snoozedUntil: nil
            )
            store._testForceSet(medications: [Self.twiceDaily()])
            store._testForceSet(todayIntakes: [optimistic])

            container.medicationSlotGate.apply(ServerVersionInfo(version: "1.35.1"))
            let derived = store.derivedTodayIntakes

            #expect(
                derived.map(\.id) == [optimistic.id],
                "the operator's own optimistic mark must not be dropped by the gate"
            )
            #expect(derived.first?.status == .taken)
        }

        // MARK: - Fixtures

        private static func twiceDaily() -> Medication {
            Medication(
                id: "med-lisinopril",
                name: "Lisinopril",
                dose: "5mg",
                schedule: MedicationSchedule(
                    times: [TimeOfDay(hour: 7, minute: 0), TimeOfDay(hour: 19, minute: 0)],
                    weekdays: nil,
                    intervalWeeks: 1
                ),
                notificationsEnabled: true,
                active: true
            )
        }

        /// A server row for today at 13:00 — more than ±5 min from both the
        /// 07:00 and the 19:00 slot, so the dedup window cannot suppress a
        /// synthesised placeholder. This is the divergence shape (schedule-era
        /// edit / DST / profile-TZ seam) that makes the phantom visible.
        private static func divergentServerDose() -> MedicationIntake {
            let onePm = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date())
            return MedicationIntake(
                id: "server-divergent",
                medicationId: "med-lisinopril",
                scheduledAt: onePm ?? Date(),
                takenAt: nil,
                status: .pending,
                snoozedUntil: nil
            )
        }

        private func makeContainer() -> AppContainer {
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
            // `AppContainer` hardwires `.standard` UserDefaults, so a verdict left
            // behind by a previous run (or by this one) must not bleed.
            container.medicationSlotGate.forget()
            return container
        }
    }

#endif // !SWIFT_PACKAGE
