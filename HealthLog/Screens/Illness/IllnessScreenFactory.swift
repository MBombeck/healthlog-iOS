import SwiftUI

/// Composition-root-free store factory. Builds an ``IllnessStore`` from the
/// public container dependencies (`api` / `outbox` / `undoCoordinator`) without
/// touching `AppContainer`. Reconcile-pass note: replace with a container-owned
/// `illnessStore` singleton and inject it (mirrors the `LabsScreenFactory`
/// note).
enum IllnessScreenFactory {
    @MainActor
    static func makeStore(container: AppContainer) -> IllnessStore {
        let repo = IllnessRepository(api: container.api, outbox: container.outbox)
        return IllnessStore(repository: repo, undo: container.undoCoordinator)
    }
}
