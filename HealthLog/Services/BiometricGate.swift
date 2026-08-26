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

    /// Trigger Face ID / Touch ID. Wirft nicht — Caller handled `Result`.
    public static func evaluate(reason: String = "HealthLog freischalten") async -> Result {
        #if canImport(LocalAuthentication)
            let context = LAContext()
            context.localizedFallbackTitle = "Geräte-Code"
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return .unavailable(error?.localizedDescription ?? "Biometric nicht verfügbar")
            }

            do {
                let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return ok ? .success : .failed("Authentifizierung abgewiesen")
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
            return .unavailable("LocalAuthentication nicht verfügbar")
        #endif
    }
}
