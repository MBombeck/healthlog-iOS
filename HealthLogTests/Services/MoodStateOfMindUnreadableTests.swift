import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// E1 — a State of Mind POST whose answer cannot be read (`HLError.decoding`,
    /// here a captive portal's HTML 200) used to be a final refusal: the anchor
    /// moved past a mood that may exist nowhere (C4, open point). Now the anchor
    /// holds; after `maxHeldSweeps` unreadable answers for the same sample it is
    /// recorded in the skip register and the page moves on.
    @Suite("State of Mind — an unreadable answer holds, then is registered", .serialized, .mockURLSession)
    struct MoodStateOfMindUnreadableTests {
        private static let portal = "<html><body>Please sign in to the Wi-Fi</body></html>"

        private static func installAnswers(readable: Flag, posts: OSAllocatedUnfairLock<Int>) {
            MockURLProtocol.install { req in
                posts.withLock { $0 += 1 }
                if readable.value {
                    return ModuleGateHarness.moodResponse(for: req, moduleOn: true)
                }
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html"]
                )!
                return (response, Data(portal.utf8))
            }
        }

        private static func sample(_ offset: Int, valence: Double = 0.5) -> HKStateOfMind {
            HKStateOfMind(
                date: Date(timeIntervalSince1970: 1_788_200_000 + TimeInterval(offset * 60)),
                kind: .momentaryEmotion,
                valence: valence,
                labels: [],
                associations: []
            )
        }

        @Test("an unreadable answer holds the anchor for a bounded run, then the sample is registered")
        func unreadableAnswerIsBounded() async throws {
            let harness = try ModuleGateHarness()
            let readable = Flag()
            let posts = OSAllocatedUnfairLock(initialState: 0)
            Self.installAnswers(readable: readable, posts: posts)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let mood = Self.sample(0, valence: -0.5)

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                for sweep in 1 ..< MoodStateOfMindUnreadable.maxHeldSweeps {
                    let page = await harness.importer.consume([mood], requiring: harness.lease)
                    #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .nonterminalEntry), "sweep \(sweep) holds")
                }
                #expect(await register.count(ownerID: "account-a") == 0)

                let released = await harness.importer.consume([mood], requiring: harness.lease)
                #expect(HealthSyncCursorPolicy.installed.decide(released) == .commit)
                let rows = await register.rows(ownerID: "account-a")
                #expect(rows.count == 1)
                #expect(rows.first?.reason == MoodStateOfMindUnreadable.reason)
                #expect(rows.first?.mood?.externalId == mood.uuid.uuidString)
                #expect(rows.first?.mood?.score == 2)
                #expect(rows.first?.entry == nil, "a mood row is never re-offered to the measurement batch")
            }
            #expect(posts.withLock { $0 } == MoodStateOfMindUnreadable.maxHeldSweeps)
            #expect(await harness.outbox.snapshot.isEmpty)
        }

        @Test("a readable answer for the held sample ends its run; the next sweep imports")
        func readableAnswerEndsTheRun() async throws {
            let harness = try ModuleGateHarness()
            let readable = Flag()
            let posts = OSAllocatedUnfairLock(initialState: 0)
            Self.installAnswers(readable: readable, posts: posts)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let samples = [Self.sample(1), Self.sample(2)]

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                let held = await harness.importer.consume(samples, requiring: harness.lease)
                #expect(HealthSyncCursorPolicy.installed.decide(held) == .hold(reason: .nonterminalEntry))
                #expect(posts.withLock { $0 } == 1, "the page stops at the unreadable answer")

                readable.value = true
                let landed = await harness.importer.consume(samples, requiring: harness.lease)
                #expect(HealthSyncCursorPolicy.installed.decide(landed) == .commit)
                #expect(landed.postedCount == 2)
            }
            #expect(await register.count(ownerID: "account-a") == 0)
        }

        private final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var flag = false

            var value: Bool {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return flag
                }
                set {
                    lock.lock()
                    defer { lock.unlock() }
                    flag = newValue
                }
            }
        }
    }

#endif

// swiftlint:enable force_unwrapping
