import Foundation

/// Pure formatting helpers for the document vault (mirror of the web
/// `vault-utils.ts` formatters). Kept nonisolated + pure so views can call them
/// during `body`.
enum DocumentFormat {
    /// Byte-size label (B / KB / MB / GB, 1024 steps), localized. Matches the web
    /// `formatBytes`: 0 fraction digits for bytes or values ≥ 100, else 1.
    static func bytes(_ byteCount: Int) -> String {
        let value = max(0, byteCount)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var unitIndex = 0
        while size >= 1024, unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // 0 digits for raw bytes or a value that rounds to ≥ 100, else 1.
        let fractionDigits = (unitIndex == 0 || size >= 100) ? 0 : 1
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: size)) ?? String(Int(size))
        return "\(number) \(units[unitIndex])"
    }

    /// Medium localized date for a `YYYY-MM-DD` filing date or an ISO instant.
    /// Anchors a date-only string at noon UTC so the calendar day never drifts.
    static func mediumDate(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return mediumFormatter.string(from: date)
    }

    /// The `YYYY-MM-DD` filing-date key for a document (documentDate if set, else
    /// the created day) — used for month bucketing / the year segmenter.
    static func dateKey(_ raw: String) -> String {
        String(raw.prefix(10))
    }

    /// Parse an ISO instant (or a `YYYY-MM-DD` day, anchored at noon UTC).
    /// Exposed for the processing-window check below.
    static func instant(_ raw: String) -> Date? {
        parse(raw)
    }

    // MARK: - Processing window (mirror of web `vault-utils.ts`)

    /// Bounded "still processing" window for a freshly uploaded document. The
    /// auto-index (+ background AI summary) job is fire-and-forget server-side
    /// and for some documents never lands at all (unsupported format, indexing
    /// disabled). Gating the card chip AND the list poll on this window means an
    /// old, permanently-unindexed document never shows a stuck spinner and the
    /// list never polls forever. Web: `RECENT_UPLOAD_WINDOW_MS = 3 min`.
    static let recentUploadWindow: TimeInterval = 3 * 60

    /// True while `createdAt` is inside the recent-upload window.
    static func isRecentlyUploaded(_ createdAt: String, now: Date = Date()) -> Bool {
        guard let created = parse(createdAt) else { return false }
        let age = now.timeIntervalSince(created)
        return age >= 0 && age < recentUploadWindow
    }

    /// The card's "Wird verarbeitet…" condition: a recently-uploaded document
    /// whose content index has not landed yet (web `isDocumentProcessing`).
    static func isProcessing(_ document: InboundDocument, now: Date = Date()) -> Bool {
        !document.hasContentIndex && isRecentlyUploaded(document.createdAt, now: now)
    }

    /// True when ANY loaded document is still processing — drives the bounded
    /// post-upload poll on the list (web `hasProcessingDocument`).
    static func hasProcessingDocument(_ documents: [InboundDocument], now: Date = Date()) -> Bool {
        documents.contains { isProcessing($0, now: now) }
    }

    // MARK: - Private

    private static func parse(_ raw: String) -> Date? {
        if raw.count == 10, let date = dayOnlyFormatter.date(from: raw + "T12:00:00Z") {
            return date
        }
        return ISO8601DateFormatter.fractional.date(from: raw)
            ?? ISO8601DateFormatter.plain.date(from: raw)
            ?? dayOnlyFormatter.date(from: raw + "T12:00:00Z")
    }

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private nonisolated(unsafe) static let dayOnlyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
