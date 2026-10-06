import Foundation
#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

/// Biometric Lock-Gate. Wird von `RootView` aufgerufen, sobald der App-Foreground
/// nach einer im Setting konfigurierten Hintergrund-Zeit zurückkehrt.
public enum BiometricGate {
    public enum Result: Sendable {
        case success
        case userCanceled
        case unavailable(String)
        case failed(String)
    }

    /// Grund, den der System-Dialog unter „Face ID"/„Code eingeben" zeigt.
    ///
    /// J1 / F2 — war fest „HealthLog freischalten", der englische Build zeigte
    /// dem Reviewer also deutschen Text im System-Prompt. Beide Texte kommen
    /// jetzt aus dem String-Katalog (en + de).
    public static var localizedReason: String {
        String(localized: "applock.prompt.reason")
    }

    /// Titel des Ausweich-Knopfs im Face-ID-Dialog (Gerätecode).
    public static var localizedFallbackTitle: String {
        String(localized: "applock.prompt.fallback")
    }

    /// Trigger Face ID / Touch ID. Wirft nicht — Caller handled `Result`.
    public static func evaluate(reason: String = BiometricGate.localizedReason) async -> Result {
        #if canImport(LocalAuthentication)
            let context = LAContext()
            context.localizedFallbackTitle = localizedFallbackTitle
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return .unavailable(error?.localizedDescription ?? "biometrics unavailable")
            }

            do {
                let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return ok ? .success : .failed("authentication rejected")
            } catch let laError as LAError {
                switch laError.code {
                case .userCancel, .systemCancel, .appCancel:
                    return .userCanceled
                case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                    return .unavailable(laError.localizedDescription)
                default:
                    return .failed(laError.localizedDescription)
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        #else
            return .unavailable("LocalAuthentication unavailable")
        #endif
    }
}
