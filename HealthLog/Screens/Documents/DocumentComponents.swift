import SwiftUI

// Shared presentation pieces for the document-vault browse screen: the
// usage/quota bar, the filter chip rail, and the document list row.

// MARK: - DocumentUsageBar

/// The storage usage/quota bar. Mirrors the web behaviour: it only appears once
/// usage crosses 80 % of quota (calm until it matters), showing the used/quota
/// label + an "almost full" note.
struct DocumentUsageBar: View {
    let usage: DocumentUsage

    private var isNearFull: Bool {
        usage.usedFraction >= 0.8
    }

    var body: some View {
        if isNearFull {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack {
                    Text("documents.upload.quotaAlmostFull")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLColor.statusWarn)
                    Spacer()
                    Text(usedLabel)
                        .font(.hlCaption.monospacedDigit())
                        .foregroundStyle(HLText.secondary)
                }
                ProgressView(value: usage.usedFraction)
                    .tint(usage.usedFraction >= 0.95 ? HLColor.statusBad : HLColor.statusWarn)
            }
            .padding(.vertical, HLSpace.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(usedLabel))
        }
    }

    private var usedLabel: String {
        let template = String(localized: "documents.upload.quotaUsed")
        return String(format: template, DocumentFormat.bytes(usage.usedBytes), DocumentFormat.bytes(usage.quotaBytes))
    }
}

// MARK: - DocumentFilterMenu

/// The native toolbar filter entry — a "Filtern" `Menu` that replaces the old
/// horizontal chip rail so the list itself reads as a first-class iOS list
/// (Files / Mail style). Holds three facets: a Type group of multi-select
/// toggles (checkmarks), a single-select linked-condition submenu, and a
/// single-select year submenu, plus a "clear filters" item when anything is
/// active. Mutates a working ``DocumentListFilter`` through plain `Binding`s and
/// calls `apply` on every change; the menu glyph fills when a filter is active.
struct DocumentFilterMenu: View {
    let filter: DocumentListFilter
    let conditionChips: [DocumentConditionLink]
    let years: [Int]
    let apply: (DocumentListFilter) -> Void
    let clear: () -> Void

    var body: some View {
        Menu {
            Section("documents.filter.kindSection") {
                ForEach(DocumentKindMeta.order) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        Label(DocumentKindMeta.labelKey(kind), systemImage: DocumentKindMeta.icon(kind))
                    }
                }
            }
            if !conditionChips.isEmpty {
                Picker("documents.filter.conditionSection", selection: episodeBinding) {
                    Text("documents.filter.allConditions").tag(String?.none)
                    ForEach(conditionChips) { chip in
                        Text(verbatim: chip.name).tag(String?.some(chip.episodeId))
                    }
                }
            }
            if !years.isEmpty {
                Picker("documents.filter.yearSection", selection: yearBinding) {
                    Text("documents.filter.allYears").tag(Int?.none)
                    ForEach(years, id: \.self) { year in
                        Text(verbatim: String(year)).tag(Int?.some(year))
                    }
                }
            }
            if filter.isActive {
                Section {
                    Button(role: .destructive, action: clear) {
                        Label("documents.filter.clear", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        } label: {
            Label(
                "documents.filter.menuTitle",
                systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel(Text("documents.filter.groupLabel"))
        .accessibilityIdentifier("documents.toolbar.filter")
    }

    private func kindBinding(_ kind: DocumentKind) -> Binding<Bool> {
        Binding(
            get: { filter.kinds.contains(kind) },
            set: { isOn in
                var next = filter
                if isOn {
                    if !next.kinds.contains(kind) { next.kinds.append(kind) }
                } else {
                    next.kinds.removeAll { $0 == kind }
                }
                apply(next)
            }
        )
    }

    private var episodeBinding: Binding<String?> {
        Binding(
            get: { filter.episodeId },
            set: { value in
                var next = filter
                next.episodeId = value
                apply(next)
            }
        )
    }

    private var yearBinding: Binding<Int?> {
        Binding(
            get: { filter.year },
            set: { value in
                var next = filter
                next.year = value
                apply(next)
            }
        )
    }
}

// MARK: - DocumentCardRow

/// One document as a list row: kind icon + title, a muted meta line
/// (date · size · filename), and a footer of condition pills + a "download-only"
/// badge for attachment-class files. In selection mode a leading checkmark
/// reflects the bulk selection.
struct DocumentCardRow: View {
    let document: InboundDocument
    let selectionMode: Bool
    let isSelected: Bool
    let isHighlighted: Bool

    /// Wave 4.6 — "Bereit" flash. The auto-index (+ background AI summary) job
    /// is fire-and-forget server-side; nothing pushes its completion. `isReady`
    /// is purely local: it flips on when a row that WAS processing while this
    /// list was on screen stops processing, so the user sees the transition
    /// instead of a chip silently disappearing. It never resurrects for a row
    /// that was already indexed when the list loaded.
    @State private var sawProcessing = false
    @State private var isReady = false

    private var isProcessing: Bool {
        DocumentFormat.isProcessing(document)
    }

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    // Audit-01 M6 — same glyph size as the kind icon beside it,
                    // so the row's leading column doesn't jump in edit mode.
                    .font(.hlHeadline)
                    .foregroundStyle(isSelected ? HLAccent.userBrandTint : HLText.tertiary)
                    .accessibilityHidden(true)
            }
            Image(systemName: DocumentKindMeta.icon(document.kind))
                .font(.hlHeadline)
                .foregroundStyle(HLText.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                // Primary line: the document title.
                Text(titleText)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(1)
                // Secondary line: the filename (only when it adds information).
                if let secondaryName {
                    Text(verbatim: secondaryName)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(1)
                }
                // Tertiary line: the muted date · size meta.
                Text(metaLine)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .lineLimit(1)
                if !document.conditionLinks.isEmpty || document.servingClass == .attachment
                    || isProcessing || isReady
                {
                    footer
                }
            }
        }
        .padding(.vertical, HLSpace.xxs)
        .listRowBackground(isHighlighted ? HLAccent.userBrandTint.opacity(0.12) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onAppear { sawProcessing = isProcessing }
        .onChange(of: isProcessing) { wasProcessing, nowProcessing in
            if wasProcessing, !nowProcessing, sawProcessing {
                isReady = true
            }
            sawProcessing = nowProcessing
        }
    }

    private var footer: some View {
        // Audit-01 C2 — ONE chip language in the footer: the condition chips
        // are `HLBadge`s like the attachment badge beside them (the former
        // hand-rolled capsule used a raw 1pt inset + its own type recipe).
        HStack(spacing: HLSpace.xxs) {
            ForEach(document.conditionLinks.prefix(3)) { link in
                HLBadge(link.name, tone: .neutral)
                    .lineLimit(1)
            }
            if document.servingClass == .attachment {
                HLBadge(
                    String(localized: "documents.card.attachmentBadge"),
                    icon: "arrow.down.circle",
                    tone: .neutral
                )
            }
            // Wave 4.6 — processing/ready feedback for the fire-and-forget
            // auto-index job. Bounded by the recent-upload window, so an old,
            // permanently-unindexed document never shows a stuck chip.
            if isProcessing {
                HLBadge(
                    String(localized: "documents.card.processing"),
                    icon: "clock.arrow.circlepath",
                    tone: .neutral
                )
                .accessibilityIdentifier("documents.card.processing")
            } else if isReady {
                HLBadge(
                    String(localized: "documents.card.ready"),
                    icon: "checkmark.circle",
                    tone: .success
                )
                .accessibilityIdentifier("documents.card.ready")
            }
        }
    }

    private var titleText: String {
        document.resolvedTitle ?? String(localized: "documents.card.untitled")
    }

    /// The filename as a secondary line — shown only when it differs from the
    /// visible title (otherwise it would just echo the primary line).
    private var secondaryName: String? {
        guard let filename = document.filename, !filename.isEmpty, filename != titleText else { return nil }
        return filename
    }

    private var metaLine: String {
        [DocumentFormat.mediumDate(document.displayDate), DocumentFormat.bytes(document.byteSize)]
            .joined(separator: " · ")
    }

    private var accessibilityText: Text {
        if let secondaryName {
            return Text("\(titleText), \(secondaryName), \(metaLine)")
        }
        return Text("\(titleText), \(metaLine)")
    }
}
