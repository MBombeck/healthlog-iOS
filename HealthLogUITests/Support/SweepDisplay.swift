import Foundation

/// **Which display a sweep run photographs.**
///
/// `HL_SWEEP_DISPLAY` names the device configuration of a run (`iphone`,
/// `iphone-dark`, `ipad13-portrait`, `ipad13-landscape`, `ipadmini`,
/// `duo-outer`, `duo-inner`, `ipad13-ax5`). The sweep writes into a sub folder
/// of that name, so runs on different displays never overwrite each other, and
/// takes appearance and text size from the same tag. The simulator itself and
/// its orientation are chosen by the run script, not here.
struct SweepDisplay: Equatable {
    /// The folder tag; empty when the run named no display.
    let tag: String

    init(environmentValue: String?) {
        let raw = (environmentValue ?? "").lowercased()
        // A tag becomes a folder name, so only a closed alphabet gets through.
        tag = String(raw.filter { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    var isNamed: Bool {
        !tag.isEmpty
    }

    /// Largest accessibility text size, requested by the `-ax5` suffix.
    var isAX5: Bool {
        tag.hasSuffix("-ax5")
    }

    /// `true`/`false` when the tag fixes the appearance, `nil` when it does not.
    /// A named display is light unless it says `-dark`.
    var wantsLight: Bool? {
        guard isNamed else { return nil }
        return !tag.hasSuffix("-dark")
    }

    /// Device orientation the tag asks for; `nil` when it names none, which the
    /// sweep treats as portrait. The sweep restores the previous orientation
    /// when a case ends.
    var wantsLandscape: Bool? {
        if tag.contains("landscape") { return true }
        if tag.contains("portrait") { return false }
        return nil
    }

    /// The sub folder of `base` this display writes to.
    func directory(under base: String) -> String {
        isNamed && !base.isEmpty ? (base as NSString).appendingPathComponent(tag) : base
    }
}
