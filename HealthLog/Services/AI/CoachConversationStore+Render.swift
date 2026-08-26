// v0.12 W8-1 — the `CoachInsight` → Markdown render helpers, split out of
// `CoachConversationStore.swift` (v0.13 W4) to keep that file under the
// SwiftLint 600-line ceiling. Both are `nonisolated static` pure functions of
// their input, so they live cleanly in an extension with no isolation cost.

import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    @available(iOS 26.0, *)
    extension CoachConversationStore {
        /// Renders a `CoachInsight.PartiallyGenerated` snapshot into the same
        /// Markdown shape as ``render(_:)``. Each partial field is `Optional`
        /// until the model emits it, so each renders only once present — the
        /// headline lands, then the body, then the bullets, no placeholder
        /// flicker.
        nonisolated static func renderPartial(_ partial: CoachInsight.PartiallyGenerated) -> String {
            var output = ""
            if let title = partial.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                output += "**" + title + "**\n\n"
            }
            if let body = partial.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                output += body
            }
            let actions = (partial.suggestedActions ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !actions.isEmpty {
                if !output.isEmpty {
                    output += "\n\n"
                }
                for action in actions {
                    output += "- " + action + "\n"
                }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        nonisolated static func render(_ insight: CoachInsight) -> String {
            var output = ""
            let trimmedTitle = insight.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                output += "**" + trimmedTitle + "**\n\n"
            }
            let trimmedBody = insight.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedBody.isEmpty {
                output += trimmedBody
            }
            let actions = insight.suggestedActions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !actions.isEmpty {
                if !output.isEmpty {
                    output += "\n\n"
                }
                for action in actions {
                    output += "- " + action + "\n"
                }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
#endif
