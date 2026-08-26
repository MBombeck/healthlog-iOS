#if canImport(Spezi) && canImport(SpeziDevices) && canImport(HealthKit)
    import HealthKit
    @_spi(APISupport) import Spezi
    import SpeziDevices

    extension AppContainer {
        /// Resolve the running `PairedDevices` module out of the booted
        /// Spezi instance and hand it to the supplied `HealthLogDeviceManager`,
        /// alongside a freshly minted `DeviceReadingForwarder` bound to the
        /// container's `MeasurementBatchUploader` + a `HealthKitDevice-
        /// ReadingWriter` over a real `HKHealthStore`.
        ///
        /// **Why a Spezi-scoped extension instead of an inline call in
        /// `AppContainer.init`?** Mirrors the `AppContainer+SpeziStandard.swift`
        /// rationale verbatim: the `@_spi(APISupport)` Spezi import + the
        /// SpeziDevices product would leak into the main `AppContainer.swift`
        /// file. Isolating the attach logic here keeps the SpeziDevices
        /// dependency surface explicit + grep-able + parallel to the
        /// HealthLogStandard attachment.
        ///
        /// Declared `static` so the call-site can run BEFORE
        /// `AppContainer.init` finishes initializing all stored properties
        /// (Swift's flow-sensitive init analysis disallows `self`-method-
        /// calls until every stored property is set), matching the
        /// `attachSpeziStandardUploader` pattern.
        ///
        /// Idempotent — `HealthLogDeviceManager.bind(to:forwarder:)` over-
        /// writes the stored references on every call. Safe to invoke on
        /// every cold launch.
        static func resolveSpeziDevicesIfAvailable(
            manager: HealthLogDeviceManager,
            uploader: MeasurementBatchUploader,
            outbox: OutboxQueue
        ) {
            Task { @MainActor in
                guard let spezi = SpeziAppDelegate.spezi else {
                    HLLog.healthKit
                        .info("Spezi not booted — SpeziDevices resolve skipped")
                    return
                }
                guard let pairedDevices = spezi.module(PairedDevices.self) else {
                    HLLog.healthKit
                        .info("PairedDevices module not registered — resolve skipped")
                    return
                }
                // Build a fresh forwarder per cold launch — the inputs
                // (uploader, HKHealthStore, outbox) are stable for the
                // process lifetime, so the resulting actor is functionally
                // a singleton even though we don't pin it on the container.
                let writer = HealthKitDeviceReadingWriter(store: HKHealthStore())
                let forwarder = DeviceReadingForwarder(
                    uploader: uploader,
                    saver: writer,
                    outbox: outbox
                )
                manager.bind(to: pairedDevices, forwarder: forwarder)
                HLLog.healthKit
                    .info("SpeziDevices PairedDevices bound + forwarder attached")
            }
        }
    }
#endif
