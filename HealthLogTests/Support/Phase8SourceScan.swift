import Foundation

/// Bounded, comment-stripped source reading for the Phase 08 contracts.
///
/// Two lessons are baked in. Phase 07 lost two assertions to doc comments that
/// named a symbol the code no longer had, so nothing here ever reads a comment.
/// Plan 08-01 then lost one to a range that ran to the end of the file and
/// matched the very member it meant to exclude, so ``member(named:in:)`` stops
/// at the declaration's own closing brace rather than at the next thing that
/// happens to look like one.
enum Phase8SourceScan {
    /// The repository root, derived from this file's own location.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Tracked source with every block and line comment removed.
    static func stripped(_ relativePath: String) throws -> String {
        let text = try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        return stripLineComments(from: stripBlockComments(from: text))
    }

    /// One declaration's own text: from its signature to the first closing brace
    /// at the signature's indentation. `nil` when the signature is absent, which
    /// callers must treat as "restate this contract", never as "satisfied".
    static func member(named signature: String, in source: String, closing: String = "}") -> String? {
        guard let start = source.range(of: signature) else { return nil }
        let indent = String(source[source.lineRange(for: start).lowerBound ..< start.lowerBound])
        let rest = source[start.lowerBound...]
        guard let close = rest.range(of: "\n\(indent)\(closing)") else { return String(rest) }
        return String(rest[..<close.upperBound])
    }

    /// Every `CGFloat` literal attached to the named `frame` dimensions inside
    /// one member — the declared hit region, in points.
    static func frameDimensions(_ labels: [String], in member: String) -> [String: Double] {
        var found: [String: Double] = [:]
        for label in labels {
            guard let range = member.range(of: "\(label): ") else { continue }
            let tail = member[range.upperBound...]
            let digits = tail.prefix { $0.isNumber || $0 == "." }
            if let value = Double(digits) { found[label] = value }
        }
        return found
    }

    /// The declared frame nearest above `anchor` — the hit region of the control
    /// that anchor identifies. Bounded to `window` characters so it can never
    /// wander into an unrelated view's geometry.
    static func frameDimensionsBefore(anchor: String, in source: String, window: Int = 600) -> [String: Double]? {
        guard let anchorRange = source.range(of: anchor) else { return nil }
        let lower = source.index(
            anchorRange.lowerBound,
            offsetBy: -window,
            limitedBy: source.startIndex
        ) ?? source.startIndex
        let region = source[lower ..< anchorRange.lowerBound]
        guard let frame = region.range(of: ".frame(", options: .backwards) else { return nil }
        let tail = region[frame.upperBound...]
        let line = tail.prefix { $0 != "\n" }
        return frameDimensions(["minWidth", "minHeight", "width", "height"], in: String(line))
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if character == "/", previous == "/", !quoted {
                    return String(line.prefix(max(0, offset - 1)))
                }
                previous = character
            }
            return String(line)
        }
        .joined(separator: "\n")
    }
}
