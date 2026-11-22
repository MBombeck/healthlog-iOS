import Foundation

/// #191 QoL — the capture picker's "Symptom". Split out of `AppRouter.swift`
/// (file length budget).
extension AppRouter {
    /// Back to Today, where the symptom quick entry is pushed on Today's own
    /// stack (``symptomQuickEntryRequestCount``), the page its quick-actions
    /// row opens. The tab flip mirrors ``requestMoodQuickEntry()``.
    func requestSymptomQuickEntry() {
        selectedTab = .home
        homePath = .init()
        symptomQuickEntryRequestCount &+= 1
    }
}
