// App-Target-Symbole (`BackgroundSyncCoordinator`, `NotificationService`) — in
// der SPM-Library nicht enthalten, der SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// **CU-21 (1) — Akzeptanz: der korrekte Trigger PRO PFAD.**
    ///
    /// `SyncTriggerBatchBodyTests` pinnt, dass der Uploader ein offenes Fenster
    /// auf den Draht bringt. Diese Suite pinnt das Stück davor, das man nicht
    /// raten darf: dass die **echten Weck-Pfade der App** dieses Fenster
    /// überhaupt öffnen — der `BGProcessingTask`, der `BGAppRefreshTask` und der
    /// Silent-Push. Getestet wird über die produktiven Einstiegspunkte
    /// (`runBGSync` / `runBGRefresh` / `didReceiveSilentNotification`), mit einem
    /// echten `MeasurementBatchUploader` am prozessweiten
    /// ``SyncTriggerContext/shared`` und echtem `APIClient` über
    /// `MockURLProtocol`.
    ///
    /// `.serialized`, weil sowohl der `MockURLProtocol.handler` als auch der
    /// prozessweite Trigger-Kontext geteilt sind.
    @Suite("CU-21 — syncTrigger pro Weck-Pfad (BGTask / Push)", .serialized)
    @MainActor
    struct SyncTriggerWakePathTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        }

        /// Uploader am **prozessweiten** Kontext — genau der, den die Weck-Pfade
        /// in Produktion beschriften.
        private func makeSharedContextUploader() -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: makeAPI(),
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
        }

        private static let entry = HealthKitBatchEntryDTO(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            value: 42,
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_716_800),
            externalId: "ext-wake"
        )

        /// Sammelt die gesendeten `syncTrigger`-Wörter.
        private final class TriggerRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []

            func record(_ body: Data) {
                guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let trigger = obj["syncTrigger"] as? String else { return }
                lock.withLock { values.append(trigger) }
            }

            var all: [String] {
                lock.withLock { values }
            }
        }

        private func installHandler(_ recorder: TriggerRecorder) {
            MockURLProtocol.handler = { req in
                if let body = req.httpBody ?? req.bodyStreamData() {
                    recorder.record(body)
                }
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let json = #"{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]}"#
                return (response, Data(json.utf8))
            }
        }

        // MARK: - BGProcessingTask

        @Test("BGProcessingTask-Wake ⇒ jeder Upload aus dem Pass trägt `background`")
        func processingWakeStampsBackground() async {
            let recorder = TriggerRecorder()
            installHandler(recorder)
            let uploader = makeSharedContextUploader()
            let coordinator = BackgroundSyncCoordinator(healthKit: MockHealthKitWriter())
            let spy = BGTaskCompletionSpy()
            // Plan 07-09 — der orchestrierte Pass ist das, was im Wake läuft;
            // hier steht er stellvertretend für „irgendein Upload während des
            // Wakes". Vorher stand der Outbox-Drain-Hook dafür, den der Wake
            // zusätzlich zum Pass aufrief.
            coordinator.attachHealthSyncRoute { _, _ in
                _ = try? await uploader.upload([Self.entry])
                return [.outboxDrain]
            }

            await coordinator.runBGSync(on: spy)

            #expect(spy.completionCount == 1)
            #expect(recorder.all == ["background"])
        }

        // MARK: - BGAppRefreshTask

        @Test("BGAppRefreshTask-Wake ⇒ Upload trägt `background`")
        func appRefreshWakeStampsBackground() async {
            let recorder = TriggerRecorder()
            installHandler(recorder)
            let uploader = makeSharedContextUploader()
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let spy = BGTaskCompletionSpy()
            coordinator.attachHealthSyncRoute { _, _ in
                _ = try? await uploader.upload([Self.entry])
                return [.outboxDrain]
            }

            await coordinator.runBGRefresh(on: spy)

            #expect(spy.completionCount == 1)
            #expect(recorder.all == ["background"])
        }

        // MARK: - Silent Push

        @Test("Silent-Push-Wake ⇒ Upload trägt `push`, nicht `background`")
        func pushWakeStampsPush() async throws {
            let recorder = TriggerRecorder()
            installHandler(recorder)
            let uploader = makeSharedContextUploader()
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            coordinator.attachHealthSyncRoute { _, _ in
                _ = try? await uploader.upload([Self.entry])
                return [.outboxDrain]
            }
            let appRouter = AppRouter()
            let deepLinks = DeepLinkRouter(router: appRouter, isAuthenticated: { true })
            let service = try NotificationService(
                api: makeAPI(),
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: deepLinks,
                backgroundSync: coordinator,
                defaults: #require(UserDefaults(suiteName: "test.cu21.push.\(UUID().uuidString)"))
            )

            _ = await service.didReceiveSilentNotification(
                userInfo: RemoteNotificationUserInfo(["aps": ["content-available": 1]])
            )

            #expect(recorder.all == ["push"])
        }

        // MARK: - Vordergrund bleibt Vordergrund

        @Test("Nach dem Wake ist das Fenster zu — der nächste Upload ist wieder `foreground`")
        func windowClosesAfterWake() async {
            let recorder = TriggerRecorder()
            installHandler(recorder)
            let uploader = makeSharedContextUploader()
            let coordinator = BackgroundSyncCoordinator(healthKit: nil)
            let spy = BGTaskCompletionSpy()
            coordinator.attachHealthSyncRoute { _, _ in
                _ = try? await uploader.upload([Self.entry])
                return [.outboxDrain]
            }

            await coordinator.runBGRefresh(on: spy)
            _ = try? await uploader.upload([Self.entry])

            #expect(recorder.all == ["background", "foreground"])
        }
    }

    // MARK: - URLRequest body-stream helper

    private extension URLRequest {
        func bodyStreamData() -> Data? {
            guard let stream = httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data.isEmpty ? nil : data
        }
    }

    // swiftlint:enable force_unwrapping

#endif
