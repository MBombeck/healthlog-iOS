import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// Phase 03-01 — the document Vision/AI routes are unusual: the request body is
/// only a document id, but that request authorizes the server to release the
/// stored original to its external provider. These tests therefore assert the
/// consent boundary at the repository wire choke point, not only in SwiftUI.
@Suite("Document AI consent lease", .serialized)
struct DocumentAIConsentLeaseTests {
    private func makeAPI(authToken: String = "ambient-token") -> APIClient {
        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString(authToken, forKey: KeychainKey.authToken)
        return APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeLease(owner: String = "user-A", bearer: String = "token-A") -> DocumentAIConsentLease {
        DocumentAIConsentLease(
            ownerUserID: owner,
            bearerToken: bearer,
            scope: .serverManaged
        )
    }

    private func response(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
        let body = #"{"data":{"documentId":"d1","indexed":true,"tokenCount":0},"error":null}"#
        return (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    @Test("Server-managed and configured-provider grants remain distinct")
    @MainActor
    func exactServerScopeIsRequired() {
        let managed = AIProviderConfig(aiAvailable: true, managedBy: "server")
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: managed,
            hasServerManagedConsent: true,
            hasConfiguredProviderConsent: false
        ) == .serverManaged)
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: managed,
            hasServerManagedConsent: false,
            hasConfiguredProviderConsent: true
        ) == nil)

        let futureProvider = AIProviderConfig(
            provider: "FUTURE_OAUTH",
            aiAvailable: true,
            managedBy: "user"
        )
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: futureProvider,
            hasServerManagedConsent: true,
            hasConfiguredProviderConsent: false
        ) == .serverManaged)

        let configured = AIProviderConfig(provider: "ANTHROPIC", hasAnthropicKey: true)
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: configured,
            hasServerManagedConsent: false,
            hasConfiguredProviderConsent: true
        ) == .serverProvider(.anthropic))
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: configured,
            hasServerManagedConsent: true,
            hasConfiguredProviderConsent: false
        ) == nil)

        let explicitlyUnavailable = AIProviderConfig(
            provider: "ANTHROPIC",
            hasAnthropicKey: true,
            aiAvailable: false,
            managedBy: "user"
        )
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: explicitlyUnavailable,
            hasServerManagedConsent: true,
            hasConfiguredProviderConsent: true
        ) == nil)

        let unavailable = AIProviderConfig()
        #expect(AppContainer.resolveDocumentAIConsentScope(
            config: unavailable,
            hasServerManagedConsent: true,
            hasConfiguredProviderConsent: true
        ) == nil)
    }

    @Test("No consent lease blocks every document-body AI trigger before URLSession")
    func noConsentMeansNoWire() async {
        let wireCount = Mutex(0)
        MockURLProtocol.handler = { request in
            wireCount.withLock { $0 += 1 }
            return response(request)
        }
        let repository = DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider { nil }
        )

        let operations: [@Sendable (DocumentsRepository) async throws -> Void] = [
            { _ = try await $0.extract(id: "d1") },
            { _ = try await $0.suggest(id: "d1") },
            { _ = try await $0.summary(id: "d1") },
            { _ = try await $0.index(id: "d1") },
            { _ = try await $0.reindexAll() }
        ]
        for operation in operations {
            await #expect(throws: DocumentAIConsentError.consentRequired) {
                try await operation(repository)
            }
        }
        await #expect(throws: DocumentChatError.consentRequired) {
            for try await _ in repository.chatStream(id: "d1", message: "question") {}
        }
        #expect(wireCount.withLock { $0 } == 0)
    }

    @Test("Chat never opens transport with a successor account bearer")
    func chatAccountBoundaryMeansNoSuccessorWire() async {
        let state = SequencedDocumentConsentState(leases: [
            makeLease(),
            makeLease(owner: "user-B", bearer: "token-B")
        ])
        let successorWireCount = Mutex(0)
        MockURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-B" {
                successorWireCount.withLock { $0 += 1 }
            }
            return response(request, sse: Self.validChatSSE)
        }
        let repository = DocumentsRepository(
            api: makeAPI(authToken: "token-B"),
            externalAIConsent: DocumentAIConsentLeaseProvider {
                await state.currentLease()
            }
        )

        await #expect(throws: DocumentChatError.consentRequired) {
            for try await _ in repository.chatStream(id: "d1", message: "question") {}
        }
        #expect(successorWireCount.withLock { $0 } == 0)
        #expect(await state.lookupCount == 2)
    }

    @Test("Chat pins the captured account bearer across ambient token rotation")
    func chatPinsCapturedBearerAndStreamsNormally() async throws {
        let seenAuthorization = Mutex<String?>(nil)
        MockURLProtocol.handler = { request in
            seenAuthorization.withLock {
                $0 = request.value(forHTTPHeaderField: "Authorization")
            }
            return response(request, sse: Self.validChatSSE)
        }
        let lease = makeLease()
        let repository = DocumentsRepository(
            api: makeAPI(authToken: "token-B"),
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )

        var frames: [DocumentChatStreamToken] = []
        for try await frame in repository.chatStream(id: "d1", message: "question") {
            frames.append(frame)
        }

        #expect(seenAuthorization.withLock { $0 } == "Bearer token-A")
        #expect(frames == [.token("ok"), .done(conversationId: "c1", messageId: "m1")])
    }

    @Test("Chat revocation before the first chunk yields no consumer side effects")
    func chatRevocationBeforeFirstChunkStopsConsumption() async {
        let currentLease = Mutex<DocumentAIConsentLease?>(makeLease())
        let api = ControlledDocumentChatAPI()
        let repository = DocumentsRepository(
            api: api,
            externalAIConsent: DocumentAIConsentLeaseProvider {
                currentLease.withLock { $0 }
            }
        )
        let consumedFrames = Mutex<[DocumentChatStreamToken]>([])
        let task = Task {
            for try await frame in repository.chatStream(id: "d1", message: "question") {
                consumedFrames.withLock { $0.append(frame) }
            }
        }

        await api.waitUntilStreamOpened()
        currentLease.withLock { $0 = nil }
        await api.emit(Self.validChatLines)

        await #expect(throws: DocumentChatError.consentRequired) {
            try await task.value
        }
        await api.waitUntilTerminationCancelled()
        #expect(consumedFrames.withLock { $0 }.isEmpty)
        #expect(await api.terminationWasCancelled)
        await api.finish()
    }

    @Test("Revocation while the lease is revalidated stops the request pre-wire")
    func revocationDuringPreflightMeansNoWire() async {
        let state = SuspendedDocumentConsentState(lease: makeLease())
        let wireCount = Mutex(0)
        MockURLProtocol.handler = { request in
            wireCount.withLock { $0 += 1 }
            return response(request)
        }
        let repository = DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider {
                await state.currentLease()
            }
        )

        let task = Task { try await repository.index(id: "d1") }
        await state.waitUntilValidationIsSuspended()
        await state.replaceLease(nil)
        await state.resumeValidation()

        await #expect(throws: DocumentAIConsentError.consentRequired) {
            _ = try await task.value
        }
        #expect(wireCount.withLock { $0 } == 0)
    }

    @Test("An account or auth-generation change invalidates the captured lease pre-wire")
    func accountBoundaryMeansNoWire() async {
        let state = SuspendedDocumentConsentState(lease: makeLease())
        let wireCount = Mutex(0)
        MockURLProtocol.handler = { request in
            wireCount.withLock { $0 += 1 }
            return response(request)
        }
        let repository = DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider {
                await state.currentLease()
            }
        )

        let task = Task { try await repository.index(id: "d1") }
        await state.waitUntilValidationIsSuspended()
        await state.replaceLease(makeLease(owner: "user-B", bearer: "token-B"))
        await state.resumeValidation()

        await #expect(throws: DocumentAIConsentError.consentRequired) {
            _ = try await task.value
        }
        #expect(wireCount.withLock { $0 } == 0)
    }

    @Test("Revocation while transport is in flight discards the response")
    func revocationAfterWireDiscardsResponse() async {
        let currentLease = Mutex<DocumentAIConsentLease?>(makeLease())
        let wireCount = Mutex(0)
        MockURLProtocol.handler = { request in
            wireCount.withLock { $0 += 1 }
            currentLease.withLock { $0 = nil }
            return response(request)
        }
        let repository = DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider {
                currentLease.withLock { $0 }
            }
        )

        await #expect(throws: DocumentAIConsentError.consentRequired) {
            _ = try await repository.index(id: "d1")
        }
        #expect(wireCount.withLock { $0 } == 1)
    }

    @Test("A current lease permits one request and pins its account bearer")
    func currentLeasePermitsPinnedRequest() async throws {
        let lease = makeLease()
        let wireCount = Mutex(0)
        MockURLProtocol.handler = { request in
            wireCount.withLock { $0 += 1 }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-A")
            return response(request)
        }
        let repository = DocumentsRepository(
            api: makeAPI(),
            externalAIConsent: DocumentAIConsentLeaseProvider { lease }
        )

        let result = try await repository.index(id: "d1")

        #expect(result.indexed)
        #expect(wireCount.withLock { $0 } == 1)
    }

    private static let validChatLines = [
        #"data: {"type":"token","token":"ok"}"#,
        #"data: {"type":"done","conversationId":"c1","messageId":"m1"}"#
    ]

    private static let validChatSSE = validChatLines.joined(separator: "\n\n") + "\n\n"

    private func response(_ request: URLRequest, sse: String) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(sse.utf8)
        )
    }
}

/// Suspends the second lease lookup, which is the repository's transport-near
/// validation. The test can revoke consent or replace the authenticated account
/// while the operation is in flight from its caller but before any wire starts.
private actor SuspendedDocumentConsentState {
    private var lease: DocumentAIConsentLease?
    private var lookupCount = 0
    private var validationWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationRelease: CheckedContinuation<Void, Never>?

    init(lease: DocumentAIConsentLease?) {
        self.lease = lease
    }

    func currentLease() async -> DocumentAIConsentLease? {
        lookupCount += 1
        if lookupCount == 2 {
            let waiters = validationWaiters
            validationWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation {
                validationRelease = $0
            }
        }
        return lease
    }

    func waitUntilValidationIsSuspended() async {
        guard lookupCount < 2 else { return }
        await withCheckedContinuation { validationWaiters.append($0) }
    }

    func replaceLease(_ lease: DocumentAIConsentLease?) {
        self.lease = lease
    }

    func resumeValidation() {
        validationRelease?.resume()
        validationRelease = nil
    }
}

private actor SequencedDocumentConsentState {
    private let leases: [DocumentAIConsentLease?]
    private var nextIndex = 0

    init(leases: [DocumentAIConsentLease?]) {
        self.leases = leases
    }

    var lookupCount: Int {
        nextIndex
    }

    func currentLease() -> DocumentAIConsentLease? {
        guard !leases.isEmpty else { return nil }
        let lease = leases[min(nextIndex, leases.count - 1)]
        nextIndex += 1
        return lease
    }
}

private actor ControlledDocumentChatAPI: APIClientProtocol {
    private enum StubError: Error {
        case unexpectedCall
    }

    private var streamContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var streamOpened = false
    private var streamWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var terminationWasCancelled = false

    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw StubError.unexpectedCall
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw StubError.unexpectedCall
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw StubError.unexpectedCall
    }

    func streamLines(_: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        streamContinuation = continuation
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.markConsumerStreamCancelled() }
        }
        streamOpened = true
        let waiters = streamWaiters
        streamWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return stream
    }

    func waitUntilStreamOpened() async {
        guard !streamOpened else { return }
        await withCheckedContinuation { streamWaiters.append($0) }
    }

    func emit(_ lines: [String]) {
        for line in lines {
            streamContinuation?.yield(line)
        }
    }

    func finish() {
        streamContinuation?.finish()
    }

    func waitUntilTerminationCancelled() async {
        guard !terminationWasCancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func markConsumerStreamCancelled() {
        terminationWasCancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
