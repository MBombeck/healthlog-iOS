import Foundation
@testable import HealthLog
import Testing

/// A360-4 QoS-1 — coverage of the cold deep-link placeholder's terminal
/// "not found" decision. The pre-fix placeholder spun forever on a failed
/// cold-start; the new `MedicationDeepLinkPlaceholder.isNotFound(...)` predicate
/// gates the calm "not found" state precisely so a still-loading or errored
/// load never reads as "not found", and a resolvable id never does either.
@Suite("MedicationDeepLinkPlaceholder — not-found gating (QoS-1)")
struct MedicationDeepLinkPlaceholderTests {
    @Test("settled, catalog loaded, id absent → not found")
    func terminalNotFound() {
        #expect(MedicationDeepLinkPlaceholder.isNotFound(
            isLoading: false, hasError: false, isCatalogEmpty: false, isResolvable: false
        ))
    }

    @Test("still loading → not 'not found' (show the spinner)")
    func loadingIsNotNotFound() {
        #expect(!MedicationDeepLinkPlaceholder.isNotFound(
            isLoading: true, hasError: false, isCatalogEmpty: false, isResolvable: false
        ))
    }

    @Test("error up → not 'not found' (the error banner owns the screen)")
    func errorIsNotNotFound() {
        #expect(!MedicationDeepLinkPlaceholder.isNotFound(
            isLoading: false, hasError: true, isCatalogEmpty: false, isResolvable: false
        ))
    }

    @Test("catalog empty (cold, not loaded yet) → not 'not found'")
    func emptyCatalogIsNotNotFound() {
        #expect(!MedicationDeepLinkPlaceholder.isNotFound(
            isLoading: false, hasError: false, isCatalogEmpty: true, isResolvable: false
        ))
    }

    @Test("id resolvable → not 'not found' (the detail screen renders)")
    func resolvableIsNotNotFound() {
        #expect(!MedicationDeepLinkPlaceholder.isNotFound(
            isLoading: false, hasError: false, isCatalogEmpty: false, isResolvable: true
        ))
    }
}
