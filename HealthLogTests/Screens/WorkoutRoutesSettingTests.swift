// App-target symbols (the settings card); the SPM test build skips the file.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Synchronization
    import Testing
    import UIKit

    /// **1.5 ROUTES (#149)** — the "Send routes" switch: off by default,
    /// the permission asked only on switching on, off stops this phone first,
    /// the server's off clears this phone, and the states render.
    @Suite("ROUTES — the route switch in Settings", .serialized)
    @MainActor
    struct WorkoutRoutesSettingTests {
        private let owner = "user-routes-settings"

        private func makeDefaults() throws -> UserDefaults {
            let suite = "routes-settings-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            KnownServerVersion.record(ServerVersionInfo(version: "1.47.0"), defaults: defaults)
            return defaults
        }

        private func model(
            _ service: FakeRouteSettingService,
            defaults: UserDefaults,
            auth: AuthProbe = AuthProbe()
        ) -> WorkoutRoutesSettingModel {
            WorkoutRoutesSettingModel(
                service: service,
                ownerUserID: owner,
                defaults: defaults,
                requestAuthorization: { try auth.request() }
            )
        }

        @Test("off by default: reading the setting asks for no permission and sends nothing")
        func offByDefault() async throws {
            let defaults = try makeDefaults()
            let service = FakeRouteSettingService(server: false)
            let auth = AuthProbe()
            let sut = model(service, defaults: defaults, auth: auth)
            await sut.load()
            #expect(sut.phase == .ready)
            #expect(!sut.isOn)
            #expect(auth.requestCount == 0)
            #expect(service.patches.isEmpty)
            #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: defaults))
        }

        @Test("on in the web alone does not start routes on this phone")
        func webOnAloneStaysOff() async throws {
            let defaults = try makeDefaults()
            let sut = model(FakeRouteSettingService(server: true), defaults: defaults)
            await sut.load()
            #expect(!sut.isOn)
            #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: defaults))
        }

        @Test("switching on asks for the permission once, then the server, then opens the gate")
        func switchOn() async throws {
            let defaults = try makeDefaults()
            let service = FakeRouteSettingService(server: false)
            let auth = AuthProbe()
            let sut = model(service, defaults: defaults, auth: auth)
            await sut.load()
            await sut.setOn(true)
            #expect(auth.requestCount == 1)
            #expect(service.patches == [true])
            #expect(sut.isOn)
            #expect(sut.saveFailure == nil)
            #expect(WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: defaults))
        }

        @Test("a refused permission request or a failed save leaves routes off")
        func switchOnFails() async throws {
            let defaults = try makeDefaults()
            let service = FakeRouteSettingService(server: false)
            let auth = AuthProbe(fails: true)
            let sut = model(service, defaults: defaults, auth: auth)
            await sut.load()
            await sut.setOn(true)
            #expect(service.patches.isEmpty)
            #expect(!sut.isOn)
            #expect(sut.saveFailure == .on)
            #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: defaults))

            let failing = FakeRouteSettingService(server: false, patchFails: true)
            let second = model(failing, defaults: defaults)
            await second.load()
            await second.setOn(true)
            #expect(!second.isOn)
            #expect(second.saveFailure == .on)
            #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: defaults))
        }

        @Test("switching off closes the gate before the request, even when the request fails")
        func switchOffLocalFirst() async throws {
            let defaults = try makeDefaults()
            WorkoutRouteOptIn.set(true, ownerUserID: owner, defaults: defaults)
            let gateAtPatch = GateProbe()
            let owner = owner
            nonisolated(unsafe) let probeDefaults = defaults
            let service = FakeRouteSettingService(server: true, patchFails: true) {
                gateAtPatch.record(WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: probeDefaults))
            }
            let sut = model(service, defaults: defaults)
            await sut.load()
            #expect(sut.isOn)
            await sut.setOn(false)
            #expect(gateAtPatch.seen == false)
            #expect(service.patches == [false])
            #expect(!sut.isOn)
            #expect(sut.saveFailure == .off)
            #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: owner, defaults: defaults))
        }

        @Test("off on the server (turned off on the web) clears this phone")
        func serverOffClearsPhone() async throws {
            let defaults = try makeDefaults()
            WorkoutRouteOptIn.set(true, ownerUserID: owner, defaults: defaults)
            let sut = model(FakeRouteSettingService(server: false), defaults: defaults)
            await sut.load()
            #expect(!sut.isOn)
            #expect(!WorkoutRouteOptIn.isOn(ownerUserID: owner, defaults: defaults))
        }

        @Test("a server without the setting is unavailable, other errors offer a retry")
        func errorStates() async throws {
            let defaults = try makeDefaults()
            let missing = model(FakeRouteSettingService(fetchError: .server(status: 404, code: nil, message: "")), defaults: defaults)
            await missing.load()
            #expect(missing.phase == .unavailable)
            let module = model(FakeRouteSettingService(fetchError: .moduleDisabled("workouts")), defaults: defaults)
            await module.load()
            #expect(module.phase == .unavailable)
            let offline = model(FakeRouteSettingService(fetchError: .offline), defaults: defaults)
            await offline.load()
            #expect(offline.phase == .failed)
            await offline.setOn(true)
            #expect(!offline.isOn, "no switch while the state is unknown")
        }

        @Test("the repository reads and writes /api/auth/me/workout-routes")
        func repositoryWire() async throws {
            let api = RouteSettingAPI()
            let repo = WorkoutRoutesSettingRepository(api: api)
            #expect(try await repo.fetch() == WorkoutRoutesSettingDTO(storeWorkoutRoutes: false))
            #expect(try await repo.update(storeWorkoutRoutes: true) == WorkoutRoutesSettingDTO(storeWorkoutRoutes: true))
            let sent = api.sent
            #expect(sent.map(\.path) == ["/api/auth/me/workout-routes", "/api/auth/me/workout-routes"])
            #expect(sent.map(\.method) == ["GET", "PATCH"])
            #expect(sent[1].body == #"{"storeWorkoutRoutes":true}"#)
        }

        // MARK: - Pictures (rule 9 and 17)

        @Test("the card renders off, on, failed save, load error and at XXXL, light and dark")
        func renders() async throws {
            let defaults = try makeDefaults()
            let off = model(FakeRouteSettingService(server: false), defaults: defaults)
            await off.load()
            let onDefaults = try makeDefaults()
            WorkoutRouteOptIn.set(true, ownerUserID: owner, defaults: onDefaults)
            let on = model(FakeRouteSettingService(server: true), defaults: onDefaults)
            await on.load()
            let offFailed = model(FakeRouteSettingService(server: true, patchFails: true), defaults: onDefaults)
            await offFailed.load()
            await offFailed.setOn(false)
            let loadFailed = model(FakeRouteSettingService(fetchError: .offline), defaults: defaults)
            await loadFailed.load()

            for style in [UIUserInterfaceStyle.light, .dark] {
                let suffix = style == .dark ? "dark" : "light"
                for (name, sut) in [("off", off), ("on", on), ("off-failed", offFailed), ("load-failed", loadFailed)] {
                    let image = try render(card(sut), name: "card-\(name)-\(suffix)", style: style)
                    #expect(Self.hasInk(image))
                }
                let link = try render(collapsedLink(), name: "advanced-link-\(suffix)", style: style, height: 120)
                #expect(Self.hasInk(link))
            }
            let big = card(off).environment(\.dynamicTypeSize, .accessibility5)
            #expect(try Self.hasInk(render(big, name: "card-off-xxxl", style: .light, height: 1600)))
        }

        private func card(_ model: WorkoutRoutesSettingModel) -> some View {
            WorkoutRoutesCard(model: model).padding(HLSpace.md)
        }

        private func collapsedLink() -> some View {
            AppleHealthWorkoutRoutesAdvanced(makeModel: {
                WorkoutRoutesSettingModel(
                    service: FakeRouteSettingService(server: false),
                    ownerUserID: nil,
                    requestAuthorization: {}
                )
            })
            .padding(HLSpace.md)
        }

        private func render(
            _ view: some View,
            name: String,
            style: UIUserInterfaceStyle,
            height: CGFloat = 360
        ) throws -> UIImage {
            let size = CGSize(width: 393, height: height)
            let host = UIHostingController(rootView: AnyView(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window.windowScene = scene
            }
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["ROUTES_RENDER_DIR"] {
                let language = Bundle.main.preferredLocalizations.first ?? "base"
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(language).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        private static func hasInk(_ image: UIImage) -> Bool {
            guard let cg = image.cgImage,
                  let data = cg.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data) else { return false }
            let length = CFDataGetLength(data)
            guard length > 8 else { return false }
            let first = (bytes[0], bytes[1], bytes[2])
            var index = 0
            while index + 2 < length {
                if (bytes[index], bytes[index + 1], bytes[index + 2]) != first { return true }
                index += 4 * 97
            }
            return false
        }
    }

    // MARK: - Doubles

    /// What the gate said at the moment the request went out.
    final class GateProbe: @unchecked Sendable {
        private let state = Mutex<Bool?>(nil)

        var seen: Bool? {
            state.withLock { $0 }
        }

        func record(_ open: Bool) {
            state.withLock { $0 = open }
        }
    }

    final class AuthProbe: @unchecked Sendable {
        private let calls = Mutex(0)
        private let fails: Bool

        init(fails: Bool = false) {
            self.fails = fails
        }

        var requestCount: Int {
            calls.withLock { $0 }
        }

        func request() throws {
            calls.withLock { $0 += 1 }
            if fails { throw HLError.unknown("denied") }
        }
    }

    final class FakeRouteSettingService: WorkoutRoutesSettingServing, @unchecked Sendable {
        private let state: Mutex<(server: Bool, patches: [Bool])>
        private let fetchError: HLError?
        private let patchFails: Bool
        private let onPatch: @Sendable () -> Void

        init(
            server: Bool = false,
            fetchError: HLError? = nil,
            patchFails: Bool = false,
            onPatch: @escaping @Sendable () -> Void = {}
        ) {
            state = Mutex((server, []))
            self.fetchError = fetchError
            self.patchFails = patchFails
            self.onPatch = onPatch
        }

        var patches: [Bool] {
            state.withLock { $0.patches }
        }

        func fetch() async throws -> WorkoutRoutesSettingDTO {
            if let fetchError { throw fetchError }
            return WorkoutRoutesSettingDTO(storeWorkoutRoutes: state.withLock { $0.server })
        }

        func update(storeWorkoutRoutes: Bool) async throws -> WorkoutRoutesSettingDTO {
            onPatch()
            state.withLock { $0.patches.append(storeWorkoutRoutes) }
            if patchFails { throw HLError.offline }
            state.withLock { $0.server = storeWorkoutRoutes }
            return WorkoutRoutesSettingDTO(storeWorkoutRoutes: storeWorkoutRoutes)
        }
    }

    final class RouteSettingAPI: APIClientProtocol, @unchecked Sendable {
        struct Sent {
            let path: String
            let method: String
            let body: String
        }

        private let log = Mutex<[Sent]>([])

        var sent: [Sent] {
            log.withLock { $0 }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log.withLock { $0.append(Sent(path: request.path, method: request.method.rawValue, body: body)) }
            let value = request.method.rawValue == "PATCH" && body.contains("true")
            guard let typed = WorkoutRoutesSettingDTO(storeWorkoutRoutes: value) as? T else {
                throw HLError.unknown("unexpected type")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

#endif
