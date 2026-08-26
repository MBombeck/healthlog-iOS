import SwiftUI

/// **N2 — the honest empty state of the nutrient surface.**
///
/// The surface had exactly one thing to say when it held no rows: „Sobald Apple
/// Health Vitamin-, Mineralstoff- oder Wasserdaten liefert, erscheinen hier die
/// Tageswerte." On an account whose `nutrients` module is OFF that sentence is
/// false in the way that costs the most: Apple Health *is* delivering, the app
/// simply never asks for it. It names a condition that is not the missing one
/// and sends the reader off to wait for something that will never arrive — which
/// is exactly what happened to the operator, who reported dietary data in Apple
/// Health and nothing on the server and never went looking for a switch, because
/// nothing on screen suggested there was one.
///
/// The states the surface actually has are three, and they are distinguishable
/// from the client with the state that already exists:
///
/// - ``moduleOff`` — the opt-in `nutrients` module is off (``ModuleGate``, or a
///   `403 module.disabled` from the route). The only case in which the reader
///   can do something and it will work, so it is the only one carrying an
///   action: the switch itself, right here (UI-Standard R4 — ein Ziel, kein
///   Wegweisersatz).
/// - ``preparing`` — module on, and this device is running its first dietary
///   read-authorization request + sync of the process (see
///   ``NutrientStore/prepareHealthKitAccessIfNeeded()``). Transient by
///   construction, and it renders as the screen's ordinary loading state: the
///   app is genuinely still working, and any sentence here would either invent a
///   cause or invite an action that is not needed.
/// - ``noData`` — module on, this device has asked, nothing came back. Here —
///   and only here — the existing sentence is true, so it stays verbatim.
///
/// **What is deliberately NOT a case: "permission denied."** HealthKit answers a
/// denied read type exactly like an empty one — no samples, no error — so the
/// app cannot know, and therefore does not say. ``noData`` covers both readings
/// without asserting either.
///
/// ``MedicationLoggingEmptyState`` is the shape this follows: a pure resolution
/// of state into one verdict, plus a render contract pinned by tests rather than
/// by reviewer vigilance.
enum NutrientEmptyState: String, Equatable, CaseIterable {
    /// The opt-in `nutrients` module is off for this account.
    case moduleOff
    /// Module on; the first authorization request + sync of this process is in
    /// flight. Claim nothing.
    case preparing
    /// Module on, this device has asked, and there is nothing to show.
    case noData

    /// Pure resolution of the two signals the store already carries.
    ///
    /// - Parameters:
    ///   - isModuleEnabled: ``NutrientStore/isModuleEnabled`` ANDed with "the
    ///     route did not answer `403 module.disabled`". Both mean the same thing
    ///     to the reader; only the source differs.
    ///   - isPreparingHealthKitAccess: ``NutrientStore/isPreparingHealthKitAccess``.
    static func resolve(isModuleEnabled: Bool, isPreparingHealthKitAccess: Bool) -> Self {
        guard isModuleEnabled else { return .moduleOff }
        return isPreparingHealthKitAccess ? .preparing : .noData
    }

    /// The one action an empty state may offer. Modelled as a value (not a
    /// closure) so "the enable path really flips the module" is pinned by a test
    /// — the view has exactly one place that maps it onto the store call.
    enum PrimaryAction: String, Equatable {
        case enableModule
    }

    /// Render contract for one empty state.
    struct Descriptor: Equatable {
        let icon: String
        let titleKey: String
        let messageKey: String
        let actionKey: String?
        let primaryAction: PrimaryAction?
    }

    /// `nil` for ``preparing`` — the loading render is the honest one there, not
    /// a copy block.
    func presentationDescriptor() -> Descriptor? {
        switch self {
        case .preparing:
            nil
        case .moduleOff:
            Descriptor(
                icon: "leaf",
                titleKey: "nutrients.list.empty.moduleOff.title",
                messageKey: "nutrients.list.empty.moduleOff.message",
                actionKey: "nutrients.list.empty.moduleOff.action",
                primaryAction: .enableModule
            )
        case .noData:
            Descriptor(
                icon: "leaf",
                titleKey: "nutrients.list.empty.title",
                messageKey: "nutrients.list.empty.subtitle",
                actionKey: nil,
                primaryAction: nil
            )
        }
    }
}

/// The lockup the nutrient list renders when it has no rows to show.
///
/// Owns the enable-CTA so the „Nährstoffe einschalten" button really flips the
/// module and runs the same authorization + sync the switchboard runs — the
/// reader lands on a working surface, not on the switchboard with one more thing
/// to figure out.
struct NutrientEmptyStateView: View {
    let state: NutrientEmptyState
    /// Flips the `nutrients` module on and prepares HealthKit access.
    let onEnableModule: () async -> Void

    @State private var isEnabling = false

    var body: some View {
        if let descriptor = state.presentationDescriptor() {
            HLEmptyState(
                icon: descriptor.icon,
                title: LocalizedStringKey(descriptor.titleKey),
                message: LocalizedStringKey(descriptor.messageKey)
            ) {
                if descriptor.primaryAction == .enableModule, let actionKey = descriptor.actionKey {
                    HLButton(
                        actionKey,
                        icon: "checkmark.circle",
                        variant: .primary,
                        isLoading: isEnabling
                    ) {
                        Task {
                            isEnabling = true
                            await onEnableModule()
                            isEnabling = false
                        }
                    }
                    .accessibilityIdentifier("nutrients.optIn.enable")
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}
