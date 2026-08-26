#if canImport(SpeziAccessGuard)
    import SpeziAccessGuard

    /// Shared SpeziAccessGuard identifiers — GH issue #8 Path 2.
    ///
    /// The app-root lock stays on the custom `BiometricGate` (W1j logout
    /// escape hatch, unified biometric+device-passcode). SpeziAccessGuard is
    /// adopted incrementally for **per-feature** sensitive surfaces where the
    /// logout escape hatch does not apply: the share-link token reveal, the
    /// health-record ZIP export, and the FHIR export.
    ///
    /// One shared identifier on purpose — a single `BiometricAccessGuard`
    /// registration in `HealthLogSpeziDelegate.configuration` covers all
    /// guarded surfaces with one timeout window, so unlocking one sensitive
    /// surface doesn't immediately re-prompt on the next (no UX regression).
    /// The raw value is persisted by SpeziAccessGuard across launches —
    /// treat it as frozen.
    extension AccessGuardIdentifier where AccessGuard == BiometricAccessGuard {
        /// Guards per-feature sensitive surfaces (share-link token,
        /// health-record ZIP export, FHIR export).
        static let sensitiveScreens: Self = .biometric("dev.healthlog.app.accessguard.sensitive-screens")
    }
#endif
