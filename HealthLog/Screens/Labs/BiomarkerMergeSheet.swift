import SwiftUI

/// #130 (server v1.43) — merge other markers into the one this sheet was
/// opened from (the person chose it as the one that stays).
///
/// Always a dry run first: the server's preview shows how many readings move,
/// how many it converts, which source it cannot convert and why, and which
/// names become aliases. Only a preview without a refusal can be confirmed,
/// and the confirmation says plainly that a merge cannot be undone. Offered
/// only where `features.biomarkerMerge` is true.
struct BiomarkerMergeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: LabsStore
    let target: BiomarkerDTO

    @State private var selected: Set<String> = []
    @State private var preview: BiomarkerMergeResult?
    @State private var isWorking = false
    @State private var inlineError: String?

    private var candidates: [BiomarkerDTO] {
        store.biomarkers.filter { $0.id != target.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(candidates) { marker in
                        candidateRow(marker)
                    }
                } header: {
                    Text(verbatim: String(localized: "labs.merge.into \(target.name)"))
                } footer: {
                    Text("labs.merge.pick.footer")
                }
                if let preview {
                    previewSection(preview)
                }
                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                }
                actionSection
            }
            .navigationTitle(Text("labs.merge.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("labs.action.cancel") { dismiss() }
                }
            }
            .onChange(of: selected) { _, _ in
                preview = nil
                inlineError = nil
            }
        }
    }

    private func candidateRow(_ marker: BiomarkerDTO) -> some View {
        Button {
            if selected.contains(marker.id) {
                selected.remove(marker.id)
            } else if selected.count < BiomarkerMergeRequest.maxSources {
                selected.insert(marker.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: marker.name).foregroundStyle(HLText.primary)
                    if let unitLabel = LabUnit.standalone(marker.unit) {
                        Text(verbatim: unitLabel).font(.hlCaption).foregroundStyle(HLText.secondary)
                    }
                }
                Spacer()
                if selected.contains(marker.id) {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected.contains(marker.id) ? .isSelected : [])
        .accessibilityIdentifier("labs.merge.candidate.\(marker.id)")
    }

    private func previewSection(_ preview: BiomarkerMergeResult) -> some View {
        Section {
            ForEach(preview.sources) { source in
                Text(verbatim: BiomarkerMergeCopy.sourceLine(source))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(BiomarkerMergeCopy.summaryLines(preview), id: \.self) { line in
                Text(verbatim: line)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("labs.merge.preview.header")
        }
        .accessibilityIdentifier("labs.merge.preview")
    }

    private var actionSection: some View {
        Section {
            if let preview, !preview.hasRefusal {
                Button(role: .destructive) {
                    Task { await confirm() }
                } label: {
                    Text("labs.merge.confirm")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("labs.merge.confirm")
            } else {
                Button("labs.merge.check") { Task { await check() } }
                    .disabled(selected.isEmpty || isWorking)
                    .accessibilityIdentifier("labs.merge.check")
            }
        } footer: {
            if let preview, !preview.hasRefusal {
                Text("labs.merge.noUndo")
            }
        }
    }

    private func check() async {
        isWorking = true
        inlineError = nil
        defer { isWorking = false }
        preview = await store.previewMerge(into: target.id, sources: Array(selected))
        if preview == nil {
            inlineError = store.lastError ?? String(localized: "labs.save.failed")
        }
    }

    private func confirm() async {
        isWorking = true
        inlineError = nil
        defer { isWorking = false }
        if await store.merge(into: target.id, sources: Array(selected)) != nil {
            dismiss()
        } else {
            inlineError = store.lastError ?? String(localized: "labs.save.failed")
        }
    }
}

/// Pure copy for the merge preview (tests pin both languages).
enum BiomarkerMergeCopy {
    static func sourceLine(_ source: BiomarkerMergeResult.Source) -> String {
        let what = switch source.conversion {
        case .none: String(localized: "labs.merge.source.same")
        case .converted: String(localized: "labs.merge.source.converted")
        case .refused, .unknown: String(localized: "labs.merge.source.refused")
        }
        return String(localized: "labs.merge.source \(source.name) \(source.readingCount) \(what)")
    }

    static func summaryLines(_ preview: BiomarkerMergeResult) -> [String] {
        if preview.hasRefusal {
            let reasons = preview.sources.filter { $0.conversion != .none && $0.conversion != .converted }
                .map { LabsRefusal.unitMismatchSentence(reason: $0.refusal ?? "") }
            var unique: [String] = []
            for reason in reasons where !unique.contains(reason) {
                unique.append(reason)
            }
            return unique + [String(localized: "labs.merge.refused")]
        }
        var lines = [String(localized: "labs.merge.moves \(preview.movedReadings) \(preview.convertedReadings)")]
        if !preview.aliasesAdded.isEmpty {
            lines.append(String(localized: "labs.merge.aliases \(preview.aliasesAdded.formatted(.list(type: .and)))"))
        }
        return lines
    }
}
