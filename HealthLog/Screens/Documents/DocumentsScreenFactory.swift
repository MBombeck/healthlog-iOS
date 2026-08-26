import SwiftUI

/// Composition-root-free store factory (mirrors `IllnessScreenFactory`). Builds a
/// ``DocumentsStore`` from the public container dependencies when the
/// container-owned singleton is somehow absent. The screens prefer
/// `container.documentsStore` (which joins the logout cascade); this is the
/// fallback only.
enum DocumentsScreenFactory {
    @MainActor
    static func makeStore(container: AppContainer) -> DocumentsStore {
        let repo = DocumentsRepository(
            api: container.api,
            externalAIConsent: container.makeDocumentAIConsentLeaseProvider()
        )
        return DocumentsStore(repository: repo, undo: container.undoCoordinator)
    }
}
