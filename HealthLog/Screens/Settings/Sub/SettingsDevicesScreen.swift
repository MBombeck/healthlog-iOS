import SwiftUI
#if canImport(SpeziDevices) && canImport(SpeziDevicesUI)
    import SpeziBluetooth
    import SpeziDevices
    import SpeziDevicesUI
#endif

/// `/settings/devices` — paired-BLE device pairing + measurement sheet host.
///
/// **v0.6.0.5 F.2 behaviour:**
/// - Mounted "Gerät hinzufügen" button now presents the SpeziDevicesUI
///   `AccessorySetupSheet`. The sheet drives the `Bluetooth` module's
///   `.scanNearbyDevices(with:)` internally on appearance — that is the
///   moment iOS asks the operator for the
///   `NSBluetoothAlwaysUsageDescription`-backed BLE permission. Until the
///   sheet is presented, no scan runs, so the launch-time invariant from
///   F.1 ("no BLE prompt on cold launch") stays in effect.
/// - `MeasurementsRecordedSheet` is wired into the screen so that as soon
///   as an Omron cuff produces a reading (post-pair, while the screen
///   stays mounted), `HealthMeasurements.shouldPresentMeasurements`
///   flips true, the sheet rises, and the operator can confirm. The save
///   callback runs through `DeviceReadingForwarder.forward(samples:)`
///   which dual-writes (HK + server) per PROJECT_GUIDE.md anti-duplicate
///   contract.
///
/// **Why mount the measurement sheet here instead of at the shell root?**
/// v0.6.0.5 ships F.2 as a self-contained slice — the operator opens
/// Settings → Geräte to pair the cuff and verify the first reading in one
/// place. Once F.3 (auto-resume measurements anywhere in the app) lands,
/// the sheet promotion to the shell root is a single file change because
/// `HealthMeasurements` already lives in the env via Spezi delegate boot.
struct SettingsDevicesScreen: View {
    /// Screen-lifetime manager. Receives its `forwarder` and live
    /// `PairedDevices`-bound projection via
    /// `AppContainer.resolveSpeziDevicesIfAvailable(manager:uploader:)`
    /// in `.task { }` below. Stays a `@State` (not env-promoted) for
    /// v0.6.0.5 so the screen renders identically in test + preview
    /// contexts where Spezi has not booted.
    @State private var manager = HealthLogDeviceManager()
    @State private var showingPairingSheet = false

    @Environment(\.appContainer) private var appContainer

    #if canImport(SpeziDevices) && canImport(SpeziDevicesUI)
        @Environment(PairedDevices.self) private var pairedDevices
        @Environment(HealthMeasurements.self) private var measurements
    #endif

    var body: some View {
        HLSettingsPage(title: "Devices") {
            pairedCard
            dualWriteFootnote
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { resolveOnAppear() }
        .onAppear { manager.refreshPairedDevices() }
        #if canImport(SpeziDevices) && canImport(SpeziDevicesUI)
            .sheet(isPresented: $showingPairingSheet) {
                // SpeziDevicesUI mounts `.scanNearbyDevices(with: bluetooth)`
                // inside the sheet body, so the BLE permission prompt fires
                // only after the operator explicitly taps "Gerät hinzufügen".
                AccessorySetupSheet(
                    pairedDevices.discoveredDevices,
                    appName: "HealthLog",
                    pairingHint: Text("Activate pairing mode on the device.")
                )
                .onDisappear { manager.refreshPairedDevices() }
            }
            .sheet(isPresented: measurementsPresentationBinding) {
                // The save callback receives the `[HKSample]` array from the
                // selected measurement (systolic + diastolic + optional heart-
                // rate for a BP reading). The forwarder dual-writes per
                // PROJECT_GUIDE.md anti-dup contract and returns count — we ignore the
                // return value here since the sheet already discards the
                // pending entry on success (`MeasurementsRecordedSheet`
                // internals).
                MeasurementsRecordedSheet { samples in
                    guard let forwarder = manager.forwarder else {
                        HLLog.healthKit
                            .info("MeasurementsRecordedSheet save called but forwarder unbound — samples dropped")
                        return
                    }
                    _ = await forwarder.forward(samples: samples)
                }
            }
        #endif
    }

    /// **R7 (Wahrheitspflicht) — der Karten-Untertitel war falsch.** Er
    /// versprach „Blutdruckmessgerät, Waage, Glukose-Sensor.", während die App
    /// genau *ein* Bluetooth-Profil kennt: `Discover(OmronBloodPressureCuff,
    /// by: .advertisedService(BloodPressureService))` in
    /// `HealthLogSpeziDelegate.swift` ist die einzige registrierte
    /// Discovery — es gibt weder ein Waagen- noch ein Glukose-Profil, also
    /// kann keines gekoppelt werden. Die zutreffende Aussage steht bereits
    /// drei Zeilen tiefer am Ort der Handlung („Unterstützt: Omron
    /// Blutdruckmessgeräte", `supportedFamiliesSubtitle`), und die wächst
    /// automatisch mit `supportedFamilies` mit. Nach R3 (eine Aussage, ein
    /// Ort) gewinnt sie; der falsche Untertitel fällt ersatzlos — R7 verlangt
    /// die Klärung vor der Kürzung, und die Klärung ergibt: nur Omron-BP.
    private var pairedCard: some View {
        HLSettingsCard(
            icon: "dot.radiowaves.left.and.right",
            title: "Paired devices"
        ) {
            if manager.pairedDevices.isEmpty {
                emptyState
            } else {
                pairedList
            }
            addDeviceRow
        }
        .accessibilityIdentifier("settings.devices.card")
    }

    /// Dual-write disclosure (v0.6.0.7 P4 — Wave-B B1-M4).
    ///
    /// Sits outside the paired-card so the operator reads the disclosure
    /// next to (not buried under) the device list. `HLText.secondary` per
    /// brief — the message is informational, not a footer hint, so it
    /// lands a notch above the tertiary "Pairing-Modus aktivieren"
    /// helper line. Wired to `devices.dualwrite.footnote` xcstring so the
    /// EN copy stays in sync with the DE primary.
    private var dualWriteFootnote: some View {
        Text("devices.dualwrite.footnote")
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HLSpace.sm)
            .padding(.top, HLSpace.xs)
            .accessibilityIdentifier("settings.devices.dualWriteFootnote")
    }

    /// Canonical `HLEmptyState` lockup. The SF Symbol matches the chip on the
    /// hub row so the operator sees visual continuity from hub → screen.
    private var emptyState: some View {
        HLEmptyState(
            icon: "dot.radiowaves.left.and.right",
            title: "No devices paired yet",
            message: "Once a Bluetooth device is paired, measurements land on your dashboard automatically."
        )
        .accessibilityIdentifier("settings.devices.emptyState")
    }

    /// Compact list rendering the snapshot the manager holds. Uses the
    /// SpeziDevices `PairedDeviceInfo` projection — the only field the
    /// row needs today is the display name plus its identifier; the rest
    /// (model variant icon, battery) is a v0.6.0.6+ design pass.
    ///
    /// **v0.6.1.5 Y5 layout fix:** rows render inside recessed
    /// `HLSurface.tertiary` wells. Pre-Y5 the rows painted directly on
    /// the card's `HLSurface.secondary` chrome — white-on-white in
    /// light mode per the operator real-device walkthrough ("habe ich
    /// einen riesen großen weißen Bar"). The recessed-well treatment
    /// matches the `HLSurface.tertiary` recipe handbook §1.2 reserves
    /// for inset rows + chip backgrounds + disabled affordances, giving
    /// the paired-list visual separation without breaking the outer
    /// card's continuity with the rest of the screen.
    @ViewBuilder
    private var pairedList: some View {
        #if canImport(SpeziDevices) && canImport(SpeziDevicesUI)
            VStack(spacing: HLSpace.sm) {
                ForEach(manager.pairedDevices, id: \.id) { info in
                    HStack(spacing: HLSpace.sm) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                        Text(info.name)
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                        Spacer(minLength: HLSpace.sm)
                    }
                    .padding(.vertical, HLSpace.sm)
                    .padding(.horizontal, HLSpace.md)
                    .background(
                        RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous)
                            .fill(HLSurface.tertiary)
                    )
                }
            }
            .accessibilityIdentifier("settings.devices.pairedList")
        #else
            EmptyView()
        #endif
    }

    private var addDeviceRow: some View {
        // v0.11.0 W37-P1: `HLSpace.sm` between the Add-button, the supported-
        // families line, and the pairing hint. The previous `.xs` packed the
        // "Supported: Omron …" line tight under the button and read out of
        // rhythm with the rest of the page (paired-list rows + dual-write
        // footnote both breathe at `.sm`). A little extra top-padding lifts the
        // helper block off the button so the card spacing harmonises.
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // R8 — eine Aktion in einer Karte ist eine Zeile; `.create` sagt
            // „öffnet ein Blatt, das etwas anlegt" und wählt das Glyph.
            HLSettingsActionRow(
                icon: "plus.circle.fill",
                title: "Add device",
                presents: .create
            ) {
                showingPairingSheet = true
            }
            .accessibilityIdentifier("settings.devices.addButton")
            supportedFamiliesSubtitle
                .padding(.top, HLSpace.xs)
            // Audit-Gruppe 7 — „Aktiviere den Pairing-Modus am Gerät, bevor du
            // auf Hinzufügen tippst." stand hier, und das Pairing-Blatt einen
            // Tap später sagt es nochmal (`pairingHint`, oben). Der Hinweis ist
            // dort handlungsnah; hier ist er Vorwegnahme. Ersatzlos gefallen.
        }
    }

    /// Supported-family subtitle below the "Gerät hinzufügen" button
    /// (v0.6.0.7 P4 — Wave-B B1-M7).
    ///
    /// Composed from two xcstrings (a `devices.add.supported.title`
    /// prefix + the comma-joined display names from
    /// `Self.supportedFamilies`). As more device families ship (scale,
    /// glucose, pulse-ox), append to `supportedFamilies` and add the
    /// matching xcstring under `devices.supported.<family>` — the view
    /// reads the list at render time so no other call-site change is
    /// needed.
    private var supportedFamiliesSubtitle: some View {
        HStack(spacing: HLSpace.xs) {
            Text("devices.add.supported.title")
            Text(Self.supportedFamilies
                .map { String(localized: $0.localizationKey) }
                .joined(separator: ", ")
            )
        }
        .font(.hlCaption)
        .foregroundStyle(HLText.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.devices.supportedFamilies")
    }

    /// Display-name list for device families the screen advertises as
    /// pair-able. Strict-extension contract: append a new
    /// `SupportedFamily` value here, add the matching xcstring under
    /// `devices.supported.<family>`, ship. No view code changes.
    private static let supportedFamilies: [SupportedFamily] = [
        .omronBloodPressure
    ]

    /// Closed enum so the supported-family list is type-checked at the
    /// call-site. A future scale/glucose adoption adds a case here and
    /// the compiler points at the missing display-name binding.
    private enum SupportedFamily {
        case omronBloodPressure

        /// xcstring key the screen renders for this family. The
        /// composed line on screen reads `devices.add.supported.title`
        /// + comma-joined `localizationKey`s.
        var localizationKey: String.LocalizationValue {
            switch self {
            case .omronBloodPressure:
                "devices.supported.omron"
            }
        }
    }

    // MARK: - Helpers

    /// Resolve the live `PairedDevices` module + bind the manager's
    /// forwarder. Idempotent — the resolver itself overwrites the manager
    /// state on every call, and the resolve path is gated on the running
    /// `SpeziAppDelegate.spezi` singleton being non-nil.
    private func resolveOnAppear() {
        guard let appContainer else { return }
        #if canImport(SpeziDevices) && canImport(SpeziDevicesUI)
            AppContainer.resolveSpeziDevicesIfAvailable(
                manager: manager,
                uploader: appContainer.healthKitUploader,
                outbox: appContainer.outbox
            )
        #endif
    }

    // Binding into the `@Observable` `HealthMeasurements.shouldPresent-
    // Measurements` field. SwiftUI's `.sheet(isPresented:)` requires a
    // concrete `Binding<Bool>`; the @Bindable pattern from the
    // SpeziDevicesUI example translates 1:1 once you hold the module
    // directly.
    #if canImport(SpeziDevices) && canImport(SpeziDevicesUI)
        private var measurementsPresentationBinding: Binding<Bool> {
            Binding(
                get: { measurements.shouldPresentMeasurements },
                set: { measurements.shouldPresentMeasurements = $0 }
            )
        }
    #endif
}

#Preview("SettingsDevicesScreen — empty") {
    NavigationStack {
        SettingsDevicesScreen()
    }
}
