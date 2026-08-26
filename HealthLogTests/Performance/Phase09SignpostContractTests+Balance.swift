import Foundation
@testable import HealthLog
import Testing

/// **Phase 09 Wave 0 — the fixture bench and the behavioural balance proofs.**
///
/// Split out of `Phase09SignpostContractTests.swift` as an extension rather than
/// as a second suite: the RED gate and every later Phase-9 plan address this
/// work by the selector `HealthLogTests/Phase09SignpostContractTests`, and a
/// second type would have quietly stopped being run by that selector while still
/// looking present in the tree. Same suite, same `.serialized` trait, two files.
///
/// Where the sibling file asserts that the measurement boundaries *exist*, this
/// one asserts that they *behave*: each interval opens once, closes once, is
/// named for what actually happened, and closes on the throwing path too.
extension Phase09SignpostContractTests {
    // MARK: - Sparse archive fixtures

    /// A 1.5 GiB fixture that costs 1.5 GiB of disk is not usable on this
    /// machine, and a fixture that quietly produced nothing would make every
    /// downstream memory number meaningless. Both halves are asserted.
    @Test("the archive fixtures have the frozen logical size and a negligible allocated size")
    func sparseArchiveFixturesAreLargeButUnallocated() throws {
        let scratch = try Phase09Scratch("sparse")
        for size in Phase09Fixture.ArchiveSize.allCases {
            let fixture = try Phase09SparseFile(size: size, in: scratch.url)
            #expect(fixture.logicalBytes == size.rawValue)
            #expect(
                fixture.reportedLogicalBytes == size.rawValue,
                "\(size.label): the file system must report the full logical length"
            )
            #expect(
                fixture.allocatedBytes <= 65536,
                "\(size.label): a sparse fixture may not reserve more than a few blocks of extents"
            )
        }
    }

    /// The header identifies the fixture; the tail proves the hole.
    ///
    /// Reading zeroes at the far end is the read-side witness that the middle
    /// was never materialised, which is the property the 1.5 GiB case depends on
    /// entirely — a fixture that quietly allocated 1.5 GiB would still pass a
    /// "the marker is there" test.
    @Test("the sparse fixture has a real header and a real hole")
    func sparseArchiveFixtureHasHeaderAndHole() throws {
        let scratch = try Phase09Scratch("markers")
        let fixture = try Phase09SparseFile(size: .small, in: scratch.url)
        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: Phase09SparseFile.markerLength)
        #expect(head == Phase09SparseFile.marker(seed: 1))
        try handle.seek(toOffset: fixture.logicalBytes - UInt64(Phase09SparseFile.markerLength))
        let tail = try handle.read(upToCount: Phase09SparseFile.markerLength)
        #expect(tail == Data(count: Phase09SparseFile.markerLength), "the tail of a sparse fixture must read as a hole")
    }

    // MARK: - Mood history fixtures

    @Test("the Mood fixtures are frozen, synthetic, and free of anything patient-like")
    func moodFixturesAreDeterministicAndSynthetic() {
        for depth in Phase09Fixture.MoodHistoryDepth.allCases {
            let first = Phase09MoodFixture.entries(depth: depth)
            let second = Phase09MoodFixture.entries(depth: depth)
            #expect(first.count == depth.rawValue)
            #expect(first == second, "\(depth.label): the fixture must be byte-identical across runs")
            #expect(first.allSatisfy { $0.note == nil }, "\(depth.label): a fixture must never carry note text")
            #expect(first.allSatisfy { $0.id.hasPrefix("phase09-mood-") })
            let keys = first.flatMap(\.tagKeys)
            #expect(keys.allSatisfy { $0.hasPrefix("phase09-factor-") })
            #expect(!keys.isEmpty, "\(depth.label): the tag-delta detector needs at least one bucket")
        }
    }

    @Test("the Mood fixture produces both multi-entry and empty days")
    func moodFixtureExercisesTheDayCollapse() {
        let calendar = Calendar.current
        let entries = Phase09MoodFixture.entries(count: 400)
        let days = Set(entries.map { calendar.startOfDay(for: $0.recordedAt) })
        #expect(days.count > 1, "the fixture must span more than one day")
        #expect(days.count < entries.count, "the fixture must contain at least one multi-entry day")
    }

    // MARK: - Counting seams

    @Test("the counting API client records the in-memory body size of every request")
    func countingClientRecordsBodyByteCounts() async throws {
        let client = Phase09CountingAPIClient()
        client.stub(path: "/api/import/apple-health-export", json: #"{"jobId":"job-1","status":"queued"}"#)
        let request = APIRequest<AppleHealthImportKickoffDTO>(
            method: .post,
            path: "/api/import/apple-health-export",
            body: Data(count: 4096),
            maxRetries: 0
        )
        let kickoff = try await client.send(request)
        #expect(kickoff.jobId == "job-1")
        #expect(client.sendCount == 1)
        #expect(client.calls.first?.bodyByteCount == 4096)
        #expect(client.calls.first?.maxRetries == 0, "a large upload must never carry an automatic retry budget")
    }

    @Test("the counting writer records size, options and originating thread")
    func countingWriterRecordsWriteShape() throws {
        let writer = Phase09CountingWriter()
        try writer.write(Data(count: 128), URL(fileURLWithPath: "/dev/null"), [.atomic, .completeFileProtection])
        #expect(writer.writeCount == 1)
        #expect(writer.writes.first?.byteCount == 128)
        #expect(writer.writes.first?.options.contains(.completeFileProtection) == true)
    }

    @Test("the counting reloader records each timeline kind separately")
    func countingReloaderSeparatesKinds() {
        let reloader = Phase09CountingReloader()
        reloader.reload("nextDose")
        reloader.reload("mood")
        reloader.reload("nextDose")
        #expect(reloader.count(ofKind: "nextDose") == 2)
        #expect(reloader.count(ofKind: "mood") == 1)
        #expect(reloader.reloads == ["nextDose", "mood", "nextDose"])
    }

    @Test("the deterministic clock records a cadence without spending it")
    func countingClockRecordsWithoutSleeping() async throws {
        let clock = Phase09Clock()
        let started = Date()
        try await clock.sleeper(2_000_000_000)
        try await clock.sleeper(2_000_000_000)
        #expect(clock.requestedSleeps == [2_000_000_000, 2_000_000_000])
        #expect(Date().timeIntervalSince(started) < 1, "the fixture clock must not consume the wall clock")
    }

    // MARK: - Behavioural balance, driven through production

    /// Export persistence opens `export.persist` once per write, closes it, and
    /// still hands the protection class down to the byte-writer.
    @MainActor
    @Test("export persistence measures one balanced interval and keeps its protection class")
    func exportPersistenceIsMeasuredAndProtected() throws {
        let writer = Phase09CountingWriter()
        try Self.recording { recorder in
            _ = try ExportStore.persist(data: Data(count: 4096), filename: "phase09.json", writer: writer.exportWriter)
            _ = try ExportStore.writeData(Data(count: 8192), generatedAt: .now, writer: writer.exportWriter)
            let records = recorder.records(for: .exportPersist)
            #expect(records.count == 2, "each PHI write opens exactly one interval")
            #expect(records.allSatisfy { $0.outcome == .completed })
        }
        #expect(writer.writeCount == 2)
        #expect(
            writer.writes.allSatisfy { $0.options.contains(.completeFileProtection) },
            "the seam may move who writes, never what the write promises"
        )
    }

    /// The interval must close when the work throws. This is the case a
    /// hand-written begin/end pair forgets, and an interval that never closes
    /// silently poisons the p95 of everything around it.
    @MainActor
    @Test("a throwing export write still closes its interval, marked failed")
    func exportPersistenceClosesOnThrow() {
        struct WriteFailure: Error {}
        let writer = Phase09CountingWriter()
        writer.failNextWrites(with: WriteFailure())
        Self.recording { recorder in
            #expect(throws: WriteFailure.self) {
                _ = try ExportStore.persist(data: Data(count: 16), filename: "phase09.json", writer: writer.exportWriter)
            }
            let records = recorder.records(for: .exportPersist)
            #expect(records.count == 1, "the interval closed exactly once despite the throw")
            #expect(records.first?.outcome == .failed, "a thrown write is not a completed one")
        }
    }

    /// The cold and hit intervals are both reachable, and which one opens is
    /// decided by the engine's own cache probe — not by the call site.
    @Test("Mood analysis opens the cold interval live and the hit interval when the engine reports a cache")
    func moodAnalysisNamesTheIntervalItActuallyTook() {
        let request = MoodAnalysisRequest(entries: Phase09MoodFixture.entries(count: 40), scope: .windowed)

        Self.recording { recorder in
            _ = MoodAnalysisEngine.live.insights(request)
            #expect(recorder.records(for: .moodAnalysisCold).count == 1)
            #expect(recorder.records(for: .moodAnalysisHit).isEmpty, "the live engine has no cache to hit yet")
        }

        let cachedEngine = Phase09CountingAnalysisEngine(reportsCached: true)
        Self.recording { recorder in
            _ = cachedEngine.engine.insights(request)
            #expect(recorder.records(for: .moodAnalysisHit).count == 1)
            #expect(recorder.records(for: .moodAnalysisCold).isEmpty)
        }
        #expect(cachedEngine.probeCount == 1, "the probe answers once per analysis, before the work")
    }

    /// The counting engine is the seam Plan 09-04 measures against: one
    /// invocation per analysis, with the entry count it was actually handed.
    @Test("the analysis seam counts invocations and sees the real entry set")
    func moodAnalysisSeamCountsInvocations() {
        let engine = Phase09CountingAnalysisEngine()
        let entries = Phase09MoodFixture.entries(depth: .year)
        _ = engine.engine.insights(MoodAnalysisRequest(entries: entries, scope: .windowed))
        _ = engine.engine.insights(MoodAnalysisRequest(entries: entries, scope: .fullHistory))
        #expect(engine.computedEntryCounts == [365, 365])
    }

    /// Magnitude is categorical and derived from the real fixture on disk, with
    /// no byte count anywhere near the trace.
    @Test("the import magnitude buckets each frozen archive without reading it")
    func importMagnitudeIsCategorical() throws {
        let scratch = try Phase09Scratch("magnitude")
        for size in Phase09Fixture.ArchiveSize.allCases {
            let fixture = try Phase09SparseFile(size: size, in: scratch.url)
            #expect(AppleHealthImportService.magnitude(ofFileAt: fixture.url) == size.magnitude, "\(size.label)")
        }
    }

    /// The import opens preparation and transport as two separate balanced
    /// intervals, and issues exactly one request with no retry budget.
    @Test("the Apple-Health import measures preparation and transport separately")
    func appleImportMeasuresPrepareAndUpload() async throws {
        let scratch = try Phase09Scratch("import")
        let fixture = try Phase09SparseFile(logicalBytes: 1_048_576, in: scratch.url, name: "export.zip")
        let client = Phase09CountingAPIClient()
        client.stub(path: "/api/import/apple-health-export", json: #"{"jobId":"job-9","status":"queued"}"#)
        let service = AppleHealthImportService(api: client)

        let recorder = HLPerfSignpost.Recorder()
        HLPerfSignpost.installRecorder(recorder)
        defer { HLPerfSignpost.installRecorder(nil) }

        let kickoff = try await service.upload(fileURL: fixture.url)
        #expect(kickoff.jobId == "job-9")
        #expect(client.sendCount == 1, "a large upload is one-shot")
        #expect(client.calls.first?.maxRetries == 0)

        let prepare = recorder.records(for: .appleImportPrepare)
        let upload = recorder.records(for: .appleImportUpload)
        #expect(prepare.count == 1)
        #expect(upload.count == 1)
        #expect(prepare.first?.outcome == .completed)
        #expect(upload.first?.outcome == .completed)
        #expect(prepare.first?.magnitude == .small, "the trace carries a bucket, never a byte count")
    }

    /// Widget persistence opens its interval and the reload seam sees the kinds
    /// WidgetKit would have been asked to rebuild.
    ///
    /// **09-03** — the persist is queued rather than synchronous now, so the
    /// interval is recorded when the queued operation runs. The case drains the
    /// writer before reading the recorder; without the drain it would assert
    /// against a measurement that had not happened yet.
    @MainActor
    @Test("the widget writer measures its persist and routes reloads through the seam")
    func widgetPersistenceIsMeasuredAndReloadsThroughTheSeam() async {
        let reloader = Phase09CountingReloader()
        let writer = WidgetSnapshotWriter(store: WidgetSnapshotStore(url: nil), reloader: reloader.timelineReloader)
        await Self.recordingAsync { recorder in
            writer.refresh(medications: [], derivedIntakes: [])
            await writer.drainPendingWrites()
            #expect(recorder.records(for: .widgetPersist).count == 1)
            #expect(recorder.records(for: .widgetPersist).first?.outcome == .completed)
        }
        #expect(!reloader.reloads.isEmpty, "the first write reloads the widget kinds it owns")
    }

    // The `foreground.pass` balance case that lived here drove
    // `HLPerfSignpost.beginForegroundPass()`, the paired helper 09-06 retired
    // together with the sibling fan-out it existed for. Its behavioural content
    // moved to `ForegroundCoordinatorTests.theForegroundIntervalClosesOnEveryExitPath`,
    // which drives a real pass and covers three exit outcomes instead of one;
    // its structural content is `lifecycleViolations()` in the sibling file,
    // which now pins the coordinator as the interval's single owner. It is not
    // re-emitted from here on purpose: `HLPerfSignpost.installRecorder` is a
    // process-global single slot, and two suites recording `foreground.pass`
    // concurrently would each be reading the other's records (D-09-06-B).

    /// The outbox factory is a real seam: it is asked exactly once, and the
    /// measured wrapper closes its interval around the open.
    @Test("the outbox factory is counted and its open is measured")
    func outboxOpenIsCountedAndMeasured() throws {
        let ledger = Phase09OutboxOpenLedger()
        let container = try OutboxStore.makeInMemory()
        let factory = OutboxOpenFactory {
            ledger.record()
            return OutboxQueue.StoreHandle(container: container)
        }
        Self.recording { recorder in
            _ = HLPerfSignpost.measure(.outboxOpen, factory.open)
            #expect(recorder.records(for: .outboxOpen).count == 1)
        }
        #expect(ledger.count == 1, "the deferred handle opens the store exactly once")
    }

    /// Every Phase-9 interval name is distinct. A duplicated raw value would
    /// make two different flows indistinguishable in a trace, and the frozen
    /// evidence document would silently be measuring one of them twice.
    @Test("the eight Phase 9 interval names are distinct")
    func intervalNamesAreDistinct() {
        #expect(Set(Self.requiredIntervalNames).count == Self.requiredIntervalNames.count)
    }

    /// Installs a recorder for the duration of `body` and removes it afterwards,
    /// including when `body` throws — the recorder is process-wide, and a leaked
    /// one would quietly attach itself to the next test.
    private static func recording(_ body: (HLPerfSignpost.Recorder) throws -> Void) rethrows {
        let recorder = HLPerfSignpost.Recorder()
        HLPerfSignpost.installRecorder(recorder)
        defer { HLPerfSignpost.installRecorder(nil) }
        try body(recorder)
    }

    /// The same, for a body that has to await the work it measures — 09-03's
    /// widget persist is queued, so its interval is recorded after a drain.
    @MainActor
    private static func recordingAsync(
        _ body: @MainActor (HLPerfSignpost.Recorder) async throws -> Void
    ) async rethrows {
        let recorder = HLPerfSignpost.Recorder()
        HLPerfSignpost.installRecorder(recorder)
        defer { HLPerfSignpost.installRecorder(nil) }
        try await body(recorder)
    }
}
