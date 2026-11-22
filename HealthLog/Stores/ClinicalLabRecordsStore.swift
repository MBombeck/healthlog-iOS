import Foundation
import Observation

/// The Health Records offer in Labs (#180).
///
/// One answer per account on this device: connect (the HealthKit sheet for
/// lab results, then a first sync) or decline (not offered again until the
/// account signs out). Nothing else in the app
/// waits for it, and nothing at launch asks: until the person taps connect on
/// the Labs screen, no Health Records permission is requested and nothing is
/// read.
@MainActor
@Observable
final class ClinicalLabRecordsStore {
    private(set) var consent: ClinicalLabRecordsConsent
    private(set) var isConnecting = false

    /// `nil` on a device that does not read Apple Health (the iPad).
    let importer: ClinicalLabRecordImporter?
    private let defaults: UserDefaults
    /// Re-read on every look: the known server version changes at run time.
    private let readsHealthKit: Bool

    init(importer: ClinicalLabRecordImporter?, readsHealthKit: Bool, defaults: UserDefaults = .standard) {
        self.importer = importer
        self.readsHealthKit = readsHealthKit
        self.defaults = defaults
        consent = ClinicalLabRecordsConsent.current(defaults: defaults)
    }

    /// The device, its HealthKit and the server can do it.
    var isAvailable: Bool {
        guard let importer else { return false }
        return ClinicalLabRecordsGate.isAvailable(
            readsHealthKit: readsHealthKit,
            supportsHealthRecords: importer.supportsHealthRecords,
            defaults: defaults
        )
    }

    /// Whether the Labs screen shows the offer.
    var offersCard: Bool {
        consent == .notAsked && isAvailable
    }

    /// Asks HealthKit for lab results and runs a first sync. Whatever the
    /// person chooses in the sheet, the offer does not come back.
    func connect() async {
        guard offersCard, let importer, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await importer.requestAuthorization()
        } catch {
            // The sheet could not be shown; the offer stays for another try.
            HLLog.healthKit.error("Health Records authorization request failed")
            return
        }
        setConsent(.requested)
        _ = await importer.sync()
    }

    func decline() {
        setConsent(.declined)
    }

    /// Sign-out: the answer belonged to the leaving account; the next one is
    /// offered the card again. The leaving account's cursor goes in the
    /// owner-bound sign-out hook, which knows its id.
    func clearOnLogout() {
        ClinicalLabRecordsConsent.clearOnLogout(defaults: defaults)
        consent = .notAsked
    }

    private func setConsent(_ value: ClinicalLabRecordsConsent) {
        ClinicalLabRecordsConsent.record(value, defaults: defaults)
        consent = value
    }
}

extension AppContainer {
    static func makeClinicalLabRecordsStore(
        api: any APIClientProtocol,
        keychain: KeychainStoring,
        idiom: DeviceIdiom
    ) -> ClinicalLabRecordsStore {
        let readsHealthKit = HealthKitAvailabilityPolicy(idiom: idiom).readsHealthKit
        return ClinicalLabRecordsStore(
            importer: makeClinicalLabRecordImporter(api: api, keychain: keychain, readsHealthKit: readsHealthKit),
            readsHealthKit: readsHealthKit
        )
    }

    /// Builds the importer for this device: none where the app does not read
    /// Apple Health or the build has no HealthKit.
    static func makeClinicalLabRecordImporter(
        api: any APIClientProtocol,
        keychain: KeychainStoring,
        readsHealthKit: Bool
    ) -> ClinicalLabRecordImporter? {
        #if canImport(HealthKit)
            guard readsHealthKit else { return nil }
            let reader = ClinicalLabRecordReader()
            return ClinicalLabRecordImporter(
                reader: reader,
                uploader: ClinicalLabRecordAPIUploader(api: api),
                isEnabled: {
                    ClinicalLabRecordsConsent.syncs(
                        isAvailable: ClinicalLabRecordsGate.isAvailable(
                            readsHealthKit: true,
                            supportsHealthRecords: reader.supportsHealthRecords
                        )
                    )
                },
                owner: { keychain.getString(forKey: KeychainKey.userID) }
            )
        #else
            return nil
        #endif
    }
}
