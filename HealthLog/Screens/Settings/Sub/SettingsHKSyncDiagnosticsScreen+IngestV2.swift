import SwiftUI

// The Apple Health types that joined in 1.7, each group with what the app
// does with it now: sent, waiting for the server, or not on this system.

extension SettingsHKSyncDiagnosticsScreen {
    var ingestV2Card: some View {
        HLCard("settings.hkdiag.ingest_v2_title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                ForEach(AppleHealthIngestStatusRow.current(), id: \.group) { row in
                    HLRow(
                        title: Text(Self.ingestV2Name(row.group)),
                        // Deletions reach only some areas yet; the row says which.
                        detail: Self.ingestV2Detail(row.group),
                        status: Self.ingestV2Status(row.state)
                    )
                }
                labRecordsRow
            }
        }
    }

    static func ingestV2Name(_ group: AppleHealthIngestStatusRow.Group) -> LocalizedStringResource {
        switch group {
        case .hypertension: "settings.hkdiag.ingest_v2.hypertension"
        case .lowCardioFitness: "settings.hkdiag.ingest_v2.low_cardio_fitness"
        case .menopause: "settings.hkdiag.ingest_v2.menopause"
        case .assessments: "settings.hkdiag.ingest_v2.assessments"
        case .symptoms: "settings.hkdiag.ingest_v2.symptoms"
        case .macros: "settings.hkdiag.ingest_v2.macros"
        case .deletes: "settings.hkdiag.ingest_v2.deletes"
        case .insulinAndBreathing: "settings.hkdiag.ingest_v2.insulin_breathing"
        case .effort: "settings.hkdiag.ingest_v2.effort"
        case .training: "settings.hkdiag.ingest_v2.training"
        case .basalTemperature: "settings.hkdiag.ingest_v2.basal_temperature"
        case .readingTimeZone: "settings.hkdiag.ingest_v2.reading_time_zone"
        }
    }

    /// Deletions name the areas they reach; macros say when nothing was
    /// readable although totals had been sent (revoked read access looks so).
    static func ingestV2Detail(_ group: AppleHealthIngestStatusRow.Group) -> Text? {
        switch group {
        case .deletes: Text("settings.hkdiag.ingest_v2.deletes_scope_all")
        case .macros where NutrientMacroDayLedger.isUnreadable(): Text("settings.hkdiag.ingest_v2.macros_unreadable")
        default: nil
        }
    }

    static func ingestV2Status(_ state: AppleHealthIngestStatusRow.State) -> HLRowStatus {
        switch state {
        case .active: HLRowStatus(String(localized: "settings.hkdiag.ingest_v2.active"), tone: .success)
        case .waitingForServer: HLRowStatus(String(localized: "settings.hkdiag.ingest_v2.waiting"), tone: .neutral)
        case .notOnThisSystem: HLRowStatus(String(localized: "settings.hkdiag.ingest_v2.not_on_system"), tone: .neutral)
        case .areaOff: HLRowStatus(String(localized: "settings.hkdiag.ingest_v2.area_off"), tone: .neutral)
        }
    }
}

/// Lab results from Health Records (#180): one row beside the 1.7 types.
extension SettingsHKSyncDiagnosticsScreen {
    var labRecordsRow: some View {
        let store = container?.clinicalLabRecordsStore
        let status = ClinicalLabRecordsStatus.current(
            readsHealthKit: store?.importer != nil,
            supportsHealthRecords: store?.importer?.supportsHealthRecords ?? false
        )
        return HLRow(
            title: Text("settings.hkdiag.ingest_v2.lab_records"),
            detail: Self.labRecordsDetail(status: status, owner: container?.keychain.getString(forKey: KeychainKey.userID)),
            status: Self.labRecordsStatus(status)
        )
    }

    /// The last pass in numbers, once there was one.
    static func labRecordsDetail(status: ClinicalLabRecordsStatus, owner: String?) -> Text? {
        guard status == .active, let owner else { return nil }
        let cursor = ClinicalLabRecordCursorStore().load(owner: owner)
        guard cursor.lastPass != nil else { return nil }
        return Text(verbatim: String(
            format: String(localized: "settings.hkdiag.ingest_v2.lab_records_last"),
            cursor.lastSent,
            cursor.lastInserted
        ))
    }

    static func labRecordsStatus(_ status: ClinicalLabRecordsStatus) -> HLRowStatus {
        switch status {
        case .active: ingestV2Status(.active)
        case .waitingForServer: ingestV2Status(.waitingForServer)
        case .notOnThisSystem: ingestV2Status(.notOnThisSystem)
        case .notConnected: HLRowStatus(String(localized: "settings.hkdiag.ingest_v2.not_connected"), tone: .neutral)
        }
    }
}
