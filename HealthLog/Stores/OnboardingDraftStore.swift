import Foundation
import Observation

/// #153 (public #27) — what the user has entered during setup, kept where a
/// view rebuild cannot reach it.
///
/// `RootPrivacyShieldPolicy` replaces the whole window content as soon as the
/// scene stops being active, and that is wanted: the app-switcher picture shows
/// the shield, never a form. It also threw away every `@State` below the root,
/// so switching to a password manager to copy a Cloudflare secret sent the user
/// back to the welcome screen with an empty address field. The flow, the
/// server step and the two Settings editors now read and write this store,
/// which the container owns and which outlives any view.
///
/// **Memory only.** Nothing here is written to `UserDefaults`, the Keychain or
/// a file; the header values are secrets until the user confirms them, and a
/// cold launch starts clean on purpose. The values are stored where they always
/// were, at the moment the user commits them (the trust confirmation on the
/// server step, Save in Settings).
@MainActor
@Observable
final class OnboardingDraftStore {
    // MARK: - Onboarding flow

    /// The step the flow stands on.
    var step: OnboardingFlow.Step = OnboardingFlow.initialStep
    var chosenMode: OnboardingMode?
    var setupScope: PostAuthenticationSetupScope = .full
    /// The answers of the address-dependent probes, so a rebuilt sign-in step
    /// shows the same doors as before instead of the optimistic defaults.
    var registrationEnabled = true
    var oidcStatus: OidcStatus = .unknown
    var webLoginAvailability: WebLoginAvailability = .probing
    /// A consumed invite token. Secret: memory only, like everything here.
    var inviteToken: String?
    /// The post-authentication completion lookup in flight. Held here so a
    /// rebuilt flow can still cancel it on sign-out.
    @ObservationIgnored var routeResolution: Task<Void, Never>?

    // MARK: - Server step

    var server = ServerAddressDraft()

    // MARK: - Settings

    /// Settings › Server › Access headers: the rows being edited, `nil` when
    /// no edit is open.
    var settingsAccessHeaderRows: [ServerAccessHeadersEditor.Row]?
    /// Settings › Server › Change server: the address being typed, `nil` when
    /// the sheet is closed.
    var changeServerAddress: String?

    init() {}

    /// Called by every flow that appears. A flow appears with no session in
    /// it (signed out, standalone pairing) or after the privacy shield
    /// rebuilt it mid-setup. Settings drafts belong to a session that is gone
    /// either way. The onboarding draft starts over when the last run reached
    /// its hand-over, or when it stands past the sign-in while no sign-in is
    /// in progress any more; otherwise the user continues where they were.
    func prepareForAppearance(phase: AuthStore.Phase) {
        settingsAccessHeaderRows = nil
        changeServerAddress = nil
        let sessionInProgress = if case .authenticating = phase { true } else { false }
        // Standalone walks the device steps without any session by design.
        let orphaned = !sessionInProgress && !step.isPreAuthentication && chosenMode != .standalone
        if step == .done || orphaned {
            resetOnboarding()
        }
    }

    /// Drops the whole onboarding draft, address and header values included.
    func resetOnboarding() {
        routeResolution?.cancel()
        routeResolution = nil
        step = OnboardingFlow.initialStep
        chosenMode = nil
        setupScope = .full
        registrationEnabled = true
        oidcStatus = .unknown
        webLoginAvailability = .probing
        inviteToken = nil
        server = ServerAddressDraft()
    }
}

/// The server step's form: the typed address and the access headers under
/// "Advanced".
struct ServerAddressDraft: Equatable {
    var address = ""
    var showsAdvanced = false
    var headerRows: [ServerAccessHeadersEditor.Row] = []
    /// `true` once the form was filled from what is already stored (a typo'd
    /// address, headers from Settings). Later visits keep the user's edits.
    var isSeeded = false
}
