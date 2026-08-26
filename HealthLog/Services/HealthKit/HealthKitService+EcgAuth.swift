import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **GH #74 / server v1.35.3 — electrocardiogram read authorization.**
    ///
    /// **16-03 / decision E2 — the type is now IN
    /// ``HealthKitService/defaultReadTypes``, the always-on first sheet.** It
    /// was kept out for as long as the reason held: a raw cardiac waveform is
    /// the most sensitive thing in the store, and until server v1.35.3 there was
    /// nowhere to send it, so asking for it in onboarding would have been asking
    /// for data the app could not use. The route exists now, and the operator
    /// decided on 2026-08-22 that a permission the app genuinely uses belongs in
    /// the dialog that asks for the rest.
    ///
    /// This entry point survives, and is not dead code: it is the path a user
    /// takes who declined the first sheet and later turns the switch on, and it
    /// stays the only ECG-specific request in the app. What changed is that it
    /// is no longer the FIRST time the question is asked.
    ///
    /// **Read-only.** The app never writes an ECG back into Apple Health, so
    /// `toShare` is empty and the type stays out of ``defaultWriteTypes``. That
    /// also means it can never distort ``HKReadinessStore``'s connection state,
    /// which is derived from write types alone — the property that lets E2
    /// enlarge the read set without moving a single existing installation's
    /// connection state.
    public extension HealthKitService {
        /// Request read authorization for `HKElectrocardiogramType`. Reached
        /// from the settings opt-in (mirrors ``requestNutrientAuthorization()``);
        /// the first sheet asks for the same type through
        /// ``HealthKitService/defaultReadTypes``.
        func requestEcgAuthorization() async throws {
            try await store.requestAuthorization(
                toShare: [],
                read: [HKObjectType.electrocardiogramType()]
            )
        }
    }

#endif
