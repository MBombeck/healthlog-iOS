// The render half of this suite hangs off App-target symbols (SwiftUI screens,
// `MoodStore`, UIKit hosting), none of which exist in the SPM library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **Phase 09 / plan 09-04 — the Mood analysis, stated in counts.**
    ///
    /// The frozen budgets this plan's flows carry are a 1 ms cache hit, a 50 ms
    /// cold analysis and a 5 ms main-thread ceiling. All three are durations, and
    /// no duration measured on a simulator may be claimed anywhere in this phase
    /// — those rows belong to the physical capture in 09-09 and stay `BLOCKED`.
    ///
    /// So nothing here is timed. What is asserted is the count-form of the same
    /// property: a repeat request for an analysis that is already resident
    /// performs **no** engine invocation at all, which is a stronger statement
    /// than "it is fast" and one a simulator can answer honestly.
    @Suite("Mood analysis — one computation per key, off the main actor")
    struct MoodAnalysisPerformanceTests {
        // MARK: - Fixtures

        /// Anchors the synthetic history one hour before today's local midnight,
        /// so the newest entries fall inside every period window under test and
        /// none of them is stamped in the future.
        @MainActor
        private static var historyEnd: Date {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(-3600)
        }

        @MainActor
        private static func history(_ count: Int) -> [MoodEntry] {
            Phase09MoodFixture.entries(count: count, endingAt: historyEnd)
        }

        @MainActor
        private static func makeStore(entryCount: Int) throws -> MoodStore {
            let store = try MoodStore(
                repo: MoodRepository(api: StubAPIClient(), outbox: OutboxQueue(inMemory: true))
            )
            store.replaceEntriesForTesting(history(entryCount))
            return store
        }

        private static func key(
            _ scope: MoodAnalysisRequest.Scope,
            periodDays: Int?,
            revision: Int,
            dayStart: Date,
            calendar: Calendar = .current,
            enrichment: MoodAnalyticsEnrichment? = nil
        ) -> MoodAnalysisKey {
            MoodAnalysisKey(
                revision: revision,
                scope: scope,
                periodDays: periodDays,
                dayStart: dayStart,
                calendar: calendar,
                enrichment: enrichment
            )
        }

        @MainActor
        private static func content(
            store: MoodStore,
            engine: MoodAnalysisEngine,
            recorder: Phase09MoodSectionRecorder,
            showsRecentSection: Bool = true
        ) -> some View {
            MoodAnalysisContent(
                period: .days30,
                editing: .constant(nil),
                showFullHistory: .constant(false),
                showsRecentSection: showsRecentSection,
                analysis: engine
            ) { index, view in
                recorder.record(index)
                return view
            }
            .environment(store)
            // The recent-entries rows read the Daylio tag catalogue during body
            // evaluation; without it a populated render traps rather than fails.
            .environment(MoodTagCatalogStore(repo: MoodTagCatalogRepository(api: StubAPIClient())))
        }

        // MARK: - One computation per key

        /// **The plan's first contract, in four unlike witnesses.**
        ///
        /// A SwiftUI body evaluation reads the windowed insight set five times
        /// (hero, stability twice, tag deltas, patterns) and the full-history
        /// spine once. Before this plan each of those reads was a fresh call into
        /// `MoodInsights.compute`, so one render of the More → Stimmung host ran
        /// the whole engine six times, and the next invalidation — a period
        /// animation, a sheet dismissal, an unrelated `@State` flip — ran it six
        /// times again.
        ///
        /// The four readings below are deliberately of different kinds: a body
        /// census, a repeat-render census, a concurrency census and a thread
        /// census. A single number that happened to be zero for the wrong reason
        /// would have to be zero for four different wrong reasons.
        @MainActor
        @Test("a repeat request for a resident Mood analysis key computes nothing")
        func repeatedRenderComputesOncePerKey() async throws {
            let ledger = Phase09MoodAnalysisLedger()
            let store = try Self.makeStore(entryCount: 365)
            let recorder = Phase09MoodSectionRecorder()

            // 1. Five renders of the production view at one unchanged key.
            //    `ImageRenderer` does run `.task`, so the analyses a render
            //    causes are counted here too — which is the honest thing to
            //    count. What may not happen is a *recomputation*: five renders
            //    of one key are still one windowed analysis and one full-history
            //    spine, where the pre-09-04 body ran six per render.
            let dayStart = Calendar.current.startOfDay(for: .now)
            let revision = store.entriesRevision
            let windowedKey = Self.key(.windowed, periodDays: 30, revision: revision, dayStart: dayStart)
            let fullKey = Self.key(.fullHistory, periodDays: nil, revision: revision, dayStart: dayStart)
            let entries = store.entries
            let cache = store.analysisCache

            for _ in 0 ..< 5 {
                let renderer = ImageRenderer(
                    content: Self.content(store: store, engine: ledger.engine, recorder: recorder)
                )
                _ = renderer.uiImage
            }
            // Asking the cache for the same two keys settles whatever the
            // renders left in flight — a request for a key already being
            // computed coalesces onto it, and a finished one is served — so the
            // figure below is exact rather than a race against the renders.
            _ = await cache.snapshot(for: windowedKey, entries: entries, engine: ledger.engine)
            _ = await cache.snapshot(for: fullKey, entries: entries, engine: ledger.engine)
            let renderComputes = ledger.computeCount
            let sectionsEmitted = recorder.indices.count

            // 2. A fresh presenter — a second view instance — against the same
            //    store. It must pay nothing.
            let before = ledger.computeCount
            await MoodAnalysisPresenter().load(
                windowed: windowedKey, fullHistory: fullKey,
                entries: entries, engine: ledger.engine, cache: cache
            )
            let repeatComputes = ledger.computeCount - before

            // 3. Thirty-two identical requests issued at once for a key nothing
            //    has asked for yet. Single-flight or not is the difference
            //    between one analysis and thirty-two.
            let burstKey = Self.key(.windowed, periodDays: 90, revision: revision, dayStart: dayStart)
            let burstEngine = ledger.engine
            let beforeBurst = ledger.computeCount
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 32 {
                    group.addTask {
                        _ = await cache.snapshot(for: burstKey, entries: entries, engine: burstEngine)
                    }
                }
            }
            let burstComputes = ledger.computeCount - beforeBurst

            let renderComputedOncePerKey = renderComputes == 2
            let repeatComputedNothing = repeatComputes == 0
            let burstCoalesced = burstComputes == 1
            let neverOnMain = ledger.mainThreadComputeCount == 0

            #expect(sectionsEmitted == 35, "five body evaluations must emit all seven sections each")
            #expect(
                renderComputedOncePerKey,
                "five renders of one key ran \(renderComputes) analyses; one windowed slice and one full-history spine is the whole bill"
            )
            #expect(repeatComputedNothing, "a second view instance recomputed \(repeatComputes) resident analyses")
            #expect(burstCoalesced, "32 identical concurrent requests produced \(burstComputes) analyses")
            #expect(neverOnMain, "\(ledger.mainThreadComputeCount) analyses ran on the thread that draws")
            #expect(
                renderComputedOncePerKey && repeatComputedNothing && burstCoalesced && neverOnMain,
                "EXPECTED_RED: Mood render recomputed an existing analysis key"
            )
        }

        // MARK: - Bounds and publication safety

        /// **The plan's second contract: the cache may not grow, and it may not
        /// answer a question that is no longer being asked.**
        ///
        /// Memoization without a bound is a leak with good manners. Four keys is
        /// the working set a Mood surface actually has — a windowed analysis and
        /// a full-history spine for the period the operator is on, and the same
        /// pair for the one they just left.
        ///
        /// The stale half is the other direction of the same risk: work computed
        /// off the main actor comes back *later*, and later is exactly when the
        /// period may have moved. The cancellation case runs its publication in
        /// its own unstructured `Task` — 09-02's finding — so the cancel targets
        /// the subject rather than Swift Testing's own task, which the framework
        /// reports as a skip inside a green run.
        @MainActor
        @Test("the Mood cache holds at most four keys and never publishes a superseded one")
        func staleResultIsRejectedAndCacheIsBounded() async throws {
            let ledger = Phase09MoodAnalysisLedger()
            let store = try Self.makeStore(entryCount: 365)
            let dayStart = Calendar.current.startOfDay(for: .now)
            let revision = store.entriesRevision
            let entries = store.entries
            let cache = store.analysisCache

            // Six distinct keys, oldest first. Two of them must be gone.
            let sixKeys = (0 ..< 6).map { index in
                Self.key(.windowed, periodDays: 10 + index, revision: revision, dayStart: dayStart)
            }
            for key in sixKeys {
                _ = await cache.snapshot(for: key, entries: entries, engine: ledger.engine)
            }
            let resident = cache.residentKeyCount()
            let newestResident = sixKeys.suffix(4).count { cache.isResident($0) }
            let oldestResident = sixKeys.prefix(2).count { cache.isResident($0) }

            // A result that returns after the period moved must not publish.
            let presenter = MoodAnalysisPresenter()
            let supersededKey = Self.key(.windowed, periodDays: 30, revision: revision, dayStart: dayStart)
            let currentKey = Self.key(.windowed, periodDays: 90, revision: revision, dayStart: dayStart)
            let superseded = await cache.snapshot(for: supersededKey, entries: entries, engine: ledger.engine)
            let current = await cache.snapshot(for: currentKey, entries: entries, engine: ledger.engine)
            presenter.adopt(windowed: currentKey, fullHistory: nil)
            let stalePublished = presenter.publish(superseded)
            let currentPublished = presenter.publish(current)

            // A cancelled publication must not land either. The task is created
            // and cancelled while this case still holds the main actor, so the
            // body cannot have run before the cancel.
            let cancelled = Task { @MainActor in presenter.publish(superseded) }
            cancelled.cancel()
            let cancelledPublished = await cancelled.value

            let bounded = resident <= MoodAnalysisCache.capacity
            let keepsNewest = newestResident == 4
            let dropsOldest = oldestResident == 0
            let rejectsStale = stalePublished == false
            let rejectsCancelled = cancelledPublished == false

            #expect(MoodAnalysisCache.capacity == 4, "the frozen residency bound is four keys")
            #expect(currentPublished, "the adopted key's own result must publish")
            #expect(!Task.isCancelled, "the cancel must have targeted the publication, not this test case")
            #expect(bounded, "\(resident) keys were resident against a bound of \(MoodAnalysisCache.capacity)")
            #expect(keepsNewest, "only \(newestResident) of the four newest keys survived")
            #expect(dropsOldest, "\(oldestResident) of the two evicted keys were still resident")
            #expect(rejectsStale, "a superseded analysis published over the current one")
            #expect(rejectsCancelled, "a cancelled analysis published")
            #expect(
                bounded && keepsNewest && dropsOldest && rejectsStale && rejectsCancelled,
                "EXPECTED_RED: Mood cache published stale or exceeded four keys"
            )
        }

        // MARK: - The key's members

        /// Every member of the key is here because changing it changes the
        /// answer. A key that ignored one of them would serve a wrong analysis;
        /// a key that carried a member the answer does not depend on would
        /// recompute for nothing.
        @MainActor
        @Test("every analysis-key member distinguishes keys, and identical members do not")
        func analysisKeyMembersDistinguishEveryDimensionThatChangesTheAnswer() {
            let dayStart = Calendar.current.startOfDay(for: .now)
            // Every calendar below names its own zone, so nothing here depends
            // on the zone the simulator happens to be set to.
            let utc = Self.calendar()
            let berlin = Self.calendar(zone: "Europe/Berlin")
            let tokyo = Self.calendar(zone: "Asia/Tokyo")
            let islamic = Self.calendar(.islamic)
            let base = Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: utc)

            let variants: [(String, MoodAnalysisKey)] = [
                ("revision", Self.key(.windowed, periodDays: 30, revision: 8, dayStart: dayStart, calendar: utc)),
                ("scope", Self.key(.fullHistory, periodDays: 30, revision: 7, dayStart: dayStart, calendar: utc)),
                ("period", Self.key(.windowed, periodDays: 90, revision: 7, dayStart: dayStart, calendar: utc)),
                (
                    "day boundary",
                    Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart.addingTimeInterval(86400), calendar: utc)
                ),
                ("calendar", Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: islamic)),
                ("time zone", Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: berlin)),
                (
                    "enrichment",
                    Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: utc, enrichment: Self.enrichment)
                )
            ]
            for (member, variant) in variants {
                #expect(variant != base, "\(member) must be a key member")
            }
            let berlinKey = Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: berlin)
            let tokyoKey = Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: tokyo)
            #expect(berlinKey != tokyoKey, "two zones are two day boundaries")

            let twin = Self.key(.windowed, periodDays: 30, revision: 7, dayStart: dayStart, calendar: utc)
            #expect(twin == base, "keys agreeing on every member must be one key")
            #expect(twin.hashValue == base.hashValue)
            #expect(base.calendarIdentifier == .gregorian)
            #expect(base.timeZoneIdentifier == "GMT", "Foundation normalises UTC to GMT")
            #expect(berlinKey.timeZoneIdentifier == "Europe/Berlin")
            #expect(islamic.identifier == .islamic)
        }

        private static func calendar(_ identifier: Calendar.Identifier = .gregorian, zone: String = "UTC") -> Calendar {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
            return calendar
        }

        static let enrichment = MoodAnalyticsEnrichment(
            slope7: 0.25, slope30: -0.1, slope90: 0.03, avg30LastMonth: 3.4, avg30LastYear: 3.1
        )

        // MARK: - Semantic equivalence

        /// The whole plan is worthless if the cached answer is a different
        /// answer. This compares the snapshot against the engine it replaces —
        /// the same `MoodInsights.compute` call the two hosts made inline —
        /// at the frozen 365-entry history and at the 10,000-entry stress depth.
        @MainActor
        @Test("a cached snapshot is byte-for-byte the analysis it replaced")
        func cachedSnapshotIsTheEngineItReplaces() async {
            let dayStart = Calendar.current.startOfDay(for: .now)
            let calendar = Calendar.current
            for depth in Phase09Fixture.MoodHistoryDepth.allCases {
                let entries = Self.history(depth.rawValue)
                let cache = MoodAnalysisCache()

                let windowedKey = Self.key(.windowed, periodDays: 30, revision: 1, dayStart: dayStart, calendar: calendar)
                let windowed = await cache.snapshot(for: windowedKey, entries: entries, engine: .live)
                let slice = MoodPeriod.days30.filter(entries, now: dayStart, calendar: calendar)
                #expect(
                    windowed.insights == MoodInsights.compute(entries: slice, now: dayStart, calendar: calendar),
                    "\(depth.label): the windowed analysis moved"
                )
                #expect(windowed.trend.map(\.date) == slice.map(\.recordedAt).sorted(), "\(depth.label): trend order")
                #expect(windowed.trend.count == slice.count, "\(depth.label): trend length")

                let fullKey = Self.key(.fullHistory, periodDays: nil, revision: 1, dayStart: dayStart, calendar: calendar)
                let full = await cache.snapshot(for: fullKey, entries: entries, engine: .live)
                #expect(
                    full.insights == MoodInsights.compute(entries: entries, now: dayStart, calendar: calendar),
                    "\(depth.label): the full-history spine moved"
                )

                let enrichedKey = Self.key(
                    .windowed, periodDays: 30, revision: 1, dayStart: dayStart,
                    calendar: calendar, enrichment: Self.enrichment
                )
                let enriched = await cache.snapshot(for: enrichedKey, entries: entries, engine: .live)
                #expect(
                    enriched.insights == MoodInsights.compute(
                        entries: slice, now: dayStart, calendar: calendar, enrichment: Self.enrichment
                    ),
                    "\(depth.label): the enrichment override must reach the cached analysis"
                )
                #expect(enriched.insights.slope7 == 0.25, "\(depth.label): the server slope must win")
            }
        }

        // MARK: - Where the work runs

        /// A thread census, not a stopwatch. The claim is *where* the analysis
        /// ran, which a simulator can answer, rather than how long it took,
        /// which it cannot.
        @MainActor
        @Test("Mood analysis never runs on the thread that draws")
        func analysisRunsOffTheMainActor() async {
            let ledger = Phase09MoodAnalysisLedger()
            let entries = Self.history(10000)
            let cache = MoodAnalysisCache()
            let dayStart = Calendar.current.startOfDay(for: .now)
            for days in [30, 90, 365] {
                _ = await cache.snapshot(
                    for: Self.key(.windowed, periodDays: days, revision: 1, dayStart: dayStart),
                    entries: entries,
                    engine: ledger.engine
                )
            }
            #expect(ledger.computeCount == 3, "three distinct windows, three analyses")
            #expect(ledger.mainThreadComputeCount == 0, "an analysis on the main actor is a dropped frame")
            #expect(ledger.invocations.allSatisfy { $0.scope == .windowed })
            #expect(ledger.invocations.map(\.entryCount).allSatisfy { $0 <= entries.count })
        }

        // MARK: - Invalidation

        /// The revision is the cheap half of the key, and it is only honest if
        /// it advances exactly when the history changed. A revalidation that
        /// returns identical entries must not advance it — throwing away a
        /// resident analysis to recompute the same numbers is the cost this plan
        /// exists to remove.
        @MainActor
        @Test("the entries revision advances on every effective mutation and on nothing else")
        func moodStoreRevisionAdvancesOnlyOnEffectiveMutation() throws {
            let store = try Self.makeStore(entryCount: 0)
            #expect(store.entriesRevision == 0)

            let seed = Self.history(12)
            store.replaceEntriesForTesting(seed)
            let afterReplace = store.entriesRevision
            #expect(afterReplace == 1, "a replacement that changed the history advances the revision")

            store.replaceEntriesForTesting(seed)
            #expect(store.entriesRevision == afterReplace, "an identical replacement is not a change")

            var added = seed
            added.insert(
                MoodEntry(id: "phase09-mood-added", recordedAt: Self.historyEnd, score: 4),
                at: 0
            )
            store.replaceEntriesForTesting(added)
            let afterAdd = store.entriesRevision
            #expect(afterAdd == afterReplace + 1, "an add advances the revision")

            var edited = added
            edited[1] = MoodEntry(id: edited[1].id, recordedAt: edited[1].recordedAt, score: edited[1].score == 5 ? 1 : 5)
            store.replaceEntriesForTesting(edited)
            let afterEdit = store.entriesRevision
            #expect(afterEdit == afterAdd + 1, "an edit that changed a score advances the revision")

            var deleted = edited
            deleted.removeFirst()
            store.replaceEntriesForTesting(deleted)
            let afterDelete = store.entriesRevision
            #expect(afterDelete == afterEdit + 1, "a delete advances the revision")

            store.clearOnLogout()
            #expect(store.entriesRevision == afterDelete + 1, "logout advances the revision")
            store.clearOnLogout()
            #expect(store.entriesRevision == afterDelete + 1, "clearing an already-empty history is not a change")
        }

        /// A signed-out account's derived analysis — daily averages, tag names,
        /// correlation sentences — must not sit in memory waiting for the next
        /// one. The revision bump alone makes the keys unreachable; the purge is
        /// what makes them gone.
        ///
        /// "Nothing is resident" is also true of a cache that never retained
        /// anything, so the witness is the recomputation: the same key asked for
        /// again after the logout has to be computed a second time. A cache that
        /// kept the previous account's answer would serve it instead.
        @MainActor
        @Test("logout drops every resident Mood analysis")
        func logoutDropsEveryResidentAnalysis() async throws {
            let ledger = Phase09MoodAnalysisLedger()
            let store = try Self.makeStore(entryCount: 365)
            let dayStart = Calendar.current.startOfDay(for: .now)
            let cache = store.analysisCache
            let key = Self.key(.windowed, periodDays: 30, revision: store.entriesRevision, dayStart: dayStart)
            let entries = store.entries
            _ = await cache.snapshot(for: key, entries: entries, engine: ledger.engine)

            store.clearOnLogout()
            #expect(cache.residentKeyCount() == 0, "a signed-out account leaves no derived analysis resident")

            _ = await cache.snapshot(for: key, entries: entries, engine: ledger.engine)
            #expect(
                ledger.computeCount == 2,
                "the same key was served from a signed-out account's residue instead of being recomputed"
            )
        }

        // MARK: - The end-to-end witness

        /// The counting contracts above all drive `MoodAnalysisPresenter`
        /// directly. This one drives the real `MoodAnalysisContent` body and
        /// asks a different question: did the render ask the cache for the key
        /// its own body builds?
        ///
        /// That is the join every other assertion here assumes and none of them
        /// proves. A body that built a subtly different key — a `Date.now`
        /// instead of the day start, a period read from the wrong place — would
        /// still compute exactly once per render and still count as "no
        /// recomputation", while recomputing on every single evaluation in
        /// production. The witness is residency under a key this test built
        /// independently, from the store's own revision and the same calendar.
        ///
        /// The settle loop yields the main actor rather than sleeping on it: the
        /// render's `.task` cannot start while this case holds the actor without
        /// suspending, and if it never lands, the expectation below is what
        /// says so.
        @MainActor
        @Test("the render asks the cache for the key its own body builds")
        func theRenderAsksTheCacheForTheKeyItsBodyBuilds() async throws {
            let ledger = Phase09MoodAnalysisLedger()
            let store = try Self.makeStore(entryCount: 365)
            let cache = store.analysisCache
            let dayStart = Calendar.current.startOfDay(for: .now)
            let revision = store.entriesRevision
            let expectedWindowed = Self.key(.windowed, periodDays: 30, revision: revision, dayStart: dayStart)
            let expectedFull = Self.key(.fullHistory, periodDays: nil, revision: revision, dayStart: dayStart)

            let renderer = ImageRenderer(
                content: Self.content(
                    store: store,
                    engine: ledger.engine,
                    recorder: Phase09MoodSectionRecorder(),
                    showsRecentSection: false
                )
            )
            _ = renderer.uiImage

            var settled = false
            for _ in 0 ..< 500 {
                if cache.isResident(expectedWindowed), cache.isResident(expectedFull) {
                    settled = true
                    break
                }
                await Task.yield()
            }

            #expect(settled, "the render never made both keys resident")
            #expect(cache.isResident(expectedWindowed), "the render never asked for the windowed key its body builds")
            #expect(cache.isResident(expectedFull), "the render never asked for the full-history spine")
            #expect(ledger.computeCount == 2, "one render asked exactly twice: \(ledger.invocations)")
            #expect(ledger.mainThreadComputeCount == 0, "and neither ran on the thread that draws")
            #expect(
                ledger.computeCount(scope: .windowed) == 1 && ledger.computeCount(scope: .fullHistory) == 1,
                "one of each scope, never two of one"
            )
        }
    }

#endif // !SWIFT_PACKAGE
