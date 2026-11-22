import SwiftUI

/// #129 (server v1.43) — Settings, Assistant: the AI usage level.
///
/// Rendered only when the server sends `ai.usage` (older servers: hidden). The
/// three options come from the server in its order; an option the operator does
/// not allow is shown disabled with its reason and is never sent. The estimate
/// beside each option is the server's, shown as an estimate; nothing here
/// computes one. A change is a `PUT /api/auth/me/ai-usage`, and the card then
/// renders the block the server answered.
struct AIUsageCard: View {
    let usage: AIUsageState
    /// Sends the choice and hands back the server's answer. Throws on a refusal.
    let choose: (AIUsageLevel) async throws -> Void

    @State private var pending: AIUsageLevel?
    @State private var failed = false

    var body: some View {
        HLCard(
            "settings.ai.usage.title",
            subtitle: "settings.ai.usage.explainer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                ForEach(usage.options, id: \.level) { option in
                    optionRow(option)
                }
                ForEach(AIUsagePresentation.notes(for: usage), id: \.self) { note in
                    Text(verbatim: note)
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failed {
                    Text("settings.ai.usage.error")
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("settings.ai.usage.error")
                }
            }
        }
        .accessibilityIdentifier("settings.ai.usage.card")
    }

    /// The mark moves at the tap and stays while the server answers; the row
    /// is locked until then.
    private func optionRow(_ option: AIUsageOption) -> some View {
        HLChoiceRow(
            title: Text(verbatim: AIUsagePresentation.label(option.level)),
            detail: AIUsagePresentation.detail(for: option).map { Text(verbatim: $0) },
            isSelected: (pending ?? usage.level) == option.level
        ) {
            Task { await select(option.level) }
        }
        .disabled(!option.allowed || pending != nil)
        .accessibilityIdentifier("settings.ai.usage.option.\(option.level.rawValue)")
    }

    private func select(_ level: AIUsageLevel) async {
        // The server's `allowed` is the only gate; a level it did not allow,
        // or the one already in effect by the person's own choice, sends nothing.
        guard usage.canChoose(level), !(usage.level == level && usage.preference == level) else { return }
        pending = level
        failed = false
        defer { pending = nil }
        do {
            try await choose(level)
        } catch {
            failed = true
        }
    }
}

extension AIUsageCard {
    /// Writes the choice, renders the answered block, then re-reads
    /// `/api/auth/me` so the capabilities the level gates follow.
    @MainActor
    static func choose(_ level: AIUsageLevel, in container: AppContainer?) async throws {
        guard let container else { return }
        let answered = try await container.settingsRepo.setAIUsage(level)
        container.aiCapabilityGate.applyUsage(answered)
        await container.moduleGate.load()
    }
}

/// Pure copy for ``AIUsageCard`` (`nonisolated` + `String`, so tests pin both
/// languages without a render pass).
enum AIUsagePresentation {
    static func label(_ level: AIUsageLevel) -> String {
        switch level {
        case .frugal: String(localized: "settings.ai.usage.level.frugal")
        case .standard: String(localized: "settings.ai.usage.level.standard")
        case .full: String(localized: "settings.ai.usage.level.full")
        }
    }

    /// The line under an option: why it is disabled, else the server's
    /// estimate, else nothing.
    static func detail(for option: AIUsageOption) -> String? {
        if !option.allowed { return String(localized: "settings.ai.usage.limited") }
        guard let tokens = option.estimatedTokensPerDay else { return nil }
        return String(localized: "settings.ai.usage.estimate \(tokens.formatted())")
    }

    /// The notes under the options: the operator's ceiling over a stored
    /// choice, and the measured use, each only when the server says so.
    static func notes(for usage: AIUsageState) -> [String] {
        var notes: [String] = []
        if usage.source == .adminCap {
            notes.append(String(localized: "settings.ai.usage.adminCap \(label(usage.level))"))
        }
        if let measured = usage.measuredTokensPerDay, usage.measuredDays > 0 {
            notes.append(String(localized: "settings.ai.usage.measured \(measured.formatted()) \(usage.measuredDays)"))
        }
        return notes
    }
}
