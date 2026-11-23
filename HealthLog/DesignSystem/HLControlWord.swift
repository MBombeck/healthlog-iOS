import SwiftUI

/// The words on the controls that recur on every screen.
///
/// A control that cancels, saves, closes, adds, deletes, edits or retries
/// takes its word from here, so the same action reads the same everywhere and
/// a change of wording is one catalog entry.
public enum HLControlWord: String, CaseIterable, Sendable {
    /// Leaves a form without keeping its input.
    case cancel = "Cancel"
    /// Keeps the input of a form.
    case save = "control.save"
    /// Leaves a screen that has nothing to keep.
    case done = "Done"
    /// Closes a sheet that only shows something.
    case close = "Close"
    /// Creates the entry a form describes.
    case add = "control.add"
    case delete = "Delete"
    case edit = "Edit"
    /// Repeats a load that failed.
    case retry = "Try again"

    /// The catalog key of the word.
    public var catalogKey: String {
        rawValue
    }

    public var key: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    public var text: Text {
        Text(key)
    }
}
