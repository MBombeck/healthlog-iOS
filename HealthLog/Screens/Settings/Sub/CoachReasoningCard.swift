import Observation
import SwiftUI

/// **1.5 COACH-R (server v1.41) — the Coach's thinking depth in Settings,
/// Assistant, under „Erweitert".**
///
/// Shown only when the server sends `coachReasoning` on `/api/auth/me`; an older
/// server, or a read that fails, leaves the page as it was in 1.4. The picker
/// binds to the person's `preference`; options above `maxLevel` are disabled as
/// limited by the operator, and the whole setting is locked while `available`
/// is false. A change is a read-modify-write of `coach-prefs.reasoning`, then a
/// fresh read of the resolved state.
@MainActor
@Observable
final class CoachReasoningSettingsModel {
    private(set) var state: CoachReasoningState?
    private(set) var pending: CoachReasoningLevel?
    private(set) var failed = false
    private let repo: AICoachSettingsRepository

    init(repo: AICoachSettingsRepository) {
        self.repo = repo
    }

    func load() async {
        state = try? await repo.fetchCoachReasoning()
    }

    func choose(_ level: CoachReasoningLevel) async {
        guard let state, state.canChoose(level), state.preference != level, pending == nil else { return }
        pending = level
        failed = false
        defer { pending = nil }
        do {
            self.state = try await repo.setCoachReasoning(level) ?? state
        } catch {
            failed = true
        }
    }
}

/// The centred „Erweitert" link under the Coach card and, once open, the card.
struct CoachReasoningAdvanced: View {
    let model: CoachReasoningSettingsModel
    @State private var expanded = false

    var body: some View {
        VStack(spacing: HLSpace.sm) {
            Button {
                withHLAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Text("Advanced")
                        .font(.hlSubhead.weight(.semibold))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.hlIcon(HLIconSize.sm))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(HLText.secondary)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.ai.advanced")
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded, let state = model.state {
                CoachReasoningCard(state: state, pending: model.pending, failed: model.failed) { level in
                    Task { await model.choose(level) }
                }
                .transition(.opacity)
            }
        }
    }
}

struct CoachReasoningCard: View {
    let state: CoachReasoningState
    let pending: CoachReasoningLevel?
    let failed: Bool
    let choose: (CoachReasoningLevel) -> Void

    var body: some View {
        HLSettingsCard(
            icon: "brain",
            title: "settings.ai.reasoning.title",
            subtitle: "settings.ai.reasoning.explainer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                ForEach(CoachReasoningLevel.allCases, id: \.self) { level in
                    optionRow(level)
                }
                ForEach(CoachReasoningPresentation.notes(for: state), id: \.self) { note in
                    Text(verbatim: note)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failed {
                    Text("settings.ai.reasoning.error")
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("settings.ai.reasoning.error")
                }
            }
        }
        .accessibilityIdentifier("settings.ai.reasoning.card")
    }

    private func optionRow(_ level: CoachReasoningLevel) -> some View {
        let allowed = state.canChoose(level)
        let selected = state.preference == level
        return Button {
            choose(level)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: CoachReasoningPresentation.label(level, offIsReal: state.offIsReal))
                        .font(.hlBody)
                        .foregroundStyle(allowed ? HLText.primary : HLText.tertiary)
                    if !state.isLocked, !allowed {
                        Text("settings.ai.usage.limited")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                Spacer(minLength: HLSpace.sm)
                if pending == level {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed || pending != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.ai.reasoning.option.\(level.rawValue)")
    }
}

/// Pure copy for ``CoachReasoningCard`` (tests pin both languages).
enum CoachReasoningPresentation {
    static func label(_ level: CoachReasoningLevel, offIsReal: Bool) -> String {
        switch level {
        case .off where offIsReal: String(localized: "settings.ai.reasoning.level.off")
        case .off: String(localized: "settings.ai.reasoning.level.minimal")
        case .low: String(localized: "settings.ai.reasoning.level.low")
        case .medium: String(localized: "settings.ai.reasoning.level.medium")
        case .high: String(localized: "settings.ai.reasoning.level.high")
        }
    }

    /// The lines under the options: why the setting is locked, or that the
    /// operator's cap holds the level below the person's choice.
    static func notes(for state: CoachReasoningState) -> [String] {
        if state.isLocked {
            return [String(localized: "settings.ai.reasoning.locked")]
        }
        if state.isCapped {
            return [String(localized: "settings.ai.usage.adminCap \(label(state.level, offIsReal: state.offIsReal))")]
        }
        return []
    }
}
