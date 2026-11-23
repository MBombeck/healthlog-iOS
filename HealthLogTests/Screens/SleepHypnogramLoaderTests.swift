// App-target symbols (`SleepHypnogramLoader`) are not in the SPM library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// D5 #3 — quick paging between nights. A load that was overtaken by a
    /// newer one (two quick taps on the arrow) must not publish its night, its
    /// error or its spinner state after its `await`.
    @Suite("Sleep hypnogram: an overtaken load publishes nothing (D5 #3)")
    @MainActor
    struct SleepHypnogramLoaderTests {
        private enum Offline: Error { case down }

        /// Parks the first fetch until the test lets it go.
        private actor Gate {
            private var parked: CheckedContinuation<Void, Never>?
            private var didPark = false
            private var parkWaiters: [CheckedContinuation<Void, Never>] = []

            func park() async {
                didPark = true
                let waiters = parkWaiters
                parkWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { parked = $0 }
            }

            func waitUntilParked() async {
                if didPark { return }
                await withCheckedContinuation { parkWaiters.append($0) }
            }

            func release() {
                parked?.resume()
                parked = nil
            }
        }

        private static func night(_ day: String) throws -> SleepNightDTO {
            let main = """
            {"night":"\(day)","source":"APPLE_HEALTH","start":"\(day)T00:30:00Z","end":"\(day)T06:30:00Z",
             "asleepMinutes":360,"inBedMinutes":360,"awakeMinutes":0,"awakenings":0,
             "stages":{},"segments":[],"reconstructed":false}
            """
            return try JSONDecoder.hlDefault.decode(SleepNightDTO.self, from: Data(#"{"main":\#(main),"naps":[]}"#.utf8))
        }

        @Test("night A answering after night B was shown does not replace B")
        func lateNightDoesNotReplaceTheNewerOne() async throws {
            let gate = Gate()
            let nightA = try Self.night("2026-11-01")
            let nightB = try Self.night("2026-11-02")
            let source = SleepNightSource(cached: { _ in nil }, fresh: { key in
                if key == "2026-11-01" {
                    await gate.park()
                    return nightA
                }
                return nightB
            })
            let loader = SleepHypnogramLoader(initialNight: nil)

            let first = Task { await loader.load(dayKey: "2026-11-01", from: source) }
            await gate.waitUntilParked()
            await loader.load(dayKey: "2026-11-02", from: source)
            #expect(loader.night == nightB)

            await gate.release()
            await first.value
            #expect(loader.night == nightB, "the overtaken load published night A under date B")
            #expect(loader.isLoading == false)
            #expect(loader.loadError == false)
        }

        @Test("an overtaken load that fails sets no error and does not stop the newer spinner")
        func lateFailureStaysSilent() async throws {
            let gateA = Gate()
            let gateB = Gate()
            let nightB = try Self.night("2026-11-02")
            let source = SleepNightSource(cached: { _ in nil }, fresh: { key in
                if key == "2026-11-01" {
                    await gateA.park()
                    throw Offline.down
                }
                await gateB.park()
                return nightB
            })
            let loader = SleepHypnogramLoader(initialNight: nil)

            let first = Task { await loader.load(dayKey: "2026-11-01", from: source) }
            await gateA.waitUntilParked()
            let second = Task { await loader.load(dayKey: "2026-11-02", from: source) }
            await gateB.waitUntilParked()

            // A fails while B is still on the wire.
            await gateA.release()
            await first.value
            #expect(loader.loadError == false, "A's failure painted the error card on B")
            #expect(loader.isLoading == true, "A's exit stopped B's spinner, so 'no data' flashed")

            await gateB.release()
            await second.value
            #expect(loader.night == nightB)
            #expect(loader.isLoading == false)
        }

        @Test("a cancelled load does not publish its night")
        func cancelledLoadPublishesNothing() async throws {
            let gate = Gate()
            let nightA = try Self.night("2026-11-01")
            let source = SleepNightSource(cached: { _ in nil }, fresh: { _ in
                await gate.park()
                return nightA
            })
            let loader = SleepHypnogramLoader(initialNight: nil)
            let first = Task { await loader.load(dayKey: "2026-11-01", from: source) }
            await gate.waitUntilParked()
            first.cancel()
            await gate.release()
            await first.value
            #expect(loader.night == nil)
        }
    }

#endif
