import SwiftUI

/// **AUDITC (1.5.0, #132, Server #614)** — the alcohol section of the life
/// circumstances: AUDIT-C.
///
/// What the server delivered and nothing more: the newest result with its sum,
/// the screening verdict only as `aboveCutoff` says it, with the guideline it
/// comes from linked (without a sex in the profile the sum alone), the earlier
/// entries each removable after a question in place, and the questionnaire,
/// unfolded in the card on request. The app adds nothing up, compares nothing
/// with the cut-off and gives no advice; every sentence around the result is
/// the server's `records.life.auditC` wording.
struct AuditCSection: View {
    let auditC: LifeAuditC
    let store: LifeCircumstancesStore
    @Bindable var model: AuditCModel

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            LifeDerivedLine(text: String(localized: "life.auditC.intro"), identifier: "life.auditC.intro")
            if let latest = auditC.latest {
                AuditCResultBlock(result: latest)
            }
            if !auditC.history.isEmpty {
                AuditCHistoryList(entries: auditC.history, store: store, model: model)
            }
            // POLISH-C (C7) — the earlier one-word answer, where the web shows it.
            if let legacy = store.legacyAlcohol {
                AuditCLegacyRow(revision: legacy, store: store, model: model)
            }
            if let instrument = auditC.instrument {
                if model.isFormOpen {
                    AuditCForm(instrument: instrument, store: store, model: model)
                } else {
                    startRow(instrument)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startRow(_ instrument: AuditCInstrument) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            if auditC.offerDue {
                LifeDerivedLine(
                    text: String(localized: "life.auditC.offerDue"),
                    secondary: true,
                    identifier: "life.auditC.offerDue"
                )
            }
            HLButton(
                auditC.latest == nil ? "life.auditC.start" : "life.auditC.again",
                variant: auditC.offerDue ? .primary : .secondary
            ) {
                withHLAnimation(.easeInOut(duration: 0.2)) { model.open(instrument) }
            }
            .accessibilityIdentifier("life.auditC.start")
        }
    }
}

/// The newest result: the sum, the date, the verdict and its source.
struct AuditCResultBlock: View {
    let result: AuditCResult

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(verbatim: String(localized: "life.auditC.result.score \(result.totalScore)"))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: HLDateFormat.date(result.takenAt, style: .long))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            if let verdict = Self.verdict(result) {
                LifeDerivedLine(text: verdict)
            }
            if case let .known(cutoff) = result.cutoff {
                LifeSourceLink(label: cutoff.sourceLabel, url: cutoff.sourceURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        // POLISH-C (C8) — iOS 26 leaves a link out of a combined label, so
        // the source line went missing for VoiceOver. The label is spelled
        // out; the link stays reachable through the combined element.
        .accessibilityLabel(Text(verbatim: Self.accessibilityText(result)))
        .accessibilityIdentifier("life.auditC.result")
    }

    /// Every line of the block in reading order, the source included.
    static func accessibilityText(_ result: AuditCResult) -> String {
        var lines = [
            String(localized: "life.auditC.result.score \(result.totalScore)"),
            HLDateFormat.date(result.takenAt, style: .long)
        ]
        if let verdict = verdict(result) { lines.append(verdict) }
        if case let .known(cutoff) = result.cutoff {
            lines.append(String(localized: "life.source \(cutoff.sourceLabel)"))
        }
        return lines.joined(separator: ", ")
    }

    /// The server's verdict in its own words: above or below the cut-off only
    /// as `aboveCutoff` says it, the "sum only" sentence for a profile
    /// without a sex, nothing for a cut-off or verdict this build cannot read.
    static func verdict(_ result: AuditCResult) -> String? {
        switch result.cutoff {
        case let .known(cutoff):
            switch result.aboveCutoff {
            case true?: String(localized: "life.auditC.result.above \(cutoff.value)")
            case false?: String(localized: "life.auditC.result.below \(cutoff.value)")
            case nil: nil
            }
        case .noSex:
            String(localized: "life.auditC.result.noCutoff")
        case .unreadable:
            nil
        }
    }
}

/// The earlier entries by their sum, each removable after a question asked
/// in place (no dialog over the record).
struct AuditCHistoryList: View {
    let entries: [AuditCHistoryEntry]
    let store: LifeCircumstancesStore
    @Bindable var model: AuditCModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("life.auditC.history")
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    row(entry)
                    if model.confirmingRemovalID == entry.id {
                        confirmation(entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ entry: AuditCHistoryEntry) -> some View {
        let date = HLDateFormat.date(entry.takenAt, style: .abbreviated)
        return HStack(spacing: HLSpace.sm) {
            Text(verbatim: String(localized: "life.auditC.historyEntry \(date) \(entry.totalScore)"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("life.auditC.history.\(entry.id)")
            Button {
                withHLAnimation(.easeInOut(duration: 0.2)) { model.askRemoval(entry.id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(HLColor.statusBad)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.removingID != nil)
            .accessibilityLabel(Text("life.auditC.remove"))
            .accessibilityValue(Text(verbatim: date))
            .accessibilityIdentifier("life.auditC.history.remove.\(entry.id)")
        }
    }

    private func confirmation(_ entry: AuditCHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("life.auditC.removeConfirmTitle")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text("life.auditC.removeConfirmBody")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.removeError {
                HLFormErrorText(error)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
                : AnyLayout(HStackLayout(spacing: HLSpace.lg))
            layout {
                Button(role: .destructive) {
                    Task { await model.remove(entry.id, store: store) }
                } label: {
                    Text("life.auditC.remove")
                        .fontWeight(.semibold)
                        .foregroundStyle(HLColor.statusBad)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("life.auditC.history.confirm.\(entry.id)")
                Button {
                    withHLAnimation(.easeInOut(duration: 0.2)) { model.confirmingRemovalID = nil }
                } label: {
                    Text("Cancel")
                        .foregroundStyle(.tint)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("life.auditC.history.cancel.\(entry.id)")
                if model.removingID == entry.id {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.hlSubhead)
            .buttonStyle(.plain)
            .disabled(model.removingID != nil)
        }
        .padding(.leading, HLSpace.sm)
    }
}
