import SwiftUI

/// How much a bar item has to stay visible when the window gets narrow.
///
/// iOS 27 lets the app say what matters; before that the system decides on
/// its own. Screens state the job here and need no availability check.
public enum HLToolbarPriority: Sendable {
    /// The page's main action (add, done, save): the last to fold away.
    case primary
    /// Left to the system.
    case standard
    /// Rarely used (sort, export): the first to fold into the overflow.
    case secondary

    @available(iOS 27.0, *)
    var system: ToolbarItemVisibilityPriority {
        switch self {
        case .primary: .high
        case .standard: .automatic
        case .secondary: .low
        }
    }
}

public extension ToolbarContent {
    /// Marks how long this item stays in a narrowing bar (iOS 27 and later;
    /// no effect before).
    func hlVisibilityPriority(_ priority: HLToolbarPriority) -> some ToolbarContent {
        HLPrioritizedToolbarContent(content: self, priority: priority)
    }
}

private struct HLPrioritizedToolbarContent<Content: ToolbarContent>: ToolbarContent {
    let content: Content
    let priority: HLToolbarPriority

    var body: some ToolbarContent {
        if #available(iOS 27.0, *) {
            content.visibilityPriority(priority.system)
        } else {
            content
        }
    }
}

/// Rare actions of a bar (export, delete, sort) in the system's overflow
/// menu on iOS 27, and in an ellipsis menu at the trailing edge before.
public struct HLToolbarOverflow<Content: View>: ToolbarContent {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu { content }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    content
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }
}
