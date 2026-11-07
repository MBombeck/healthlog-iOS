import Foundation

// MARK: - Recently deleted (#151, server v1.46.0)

/// One row of `GET /api/documents/inbound/deleted`: metadata only, never the
/// file. Decoded tolerantly; only `id` is required, a row without it is
/// dropped by ``DeletedDocumentList``.
public struct DeletedDocument: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: DocumentKind
    public let title: String?
    public let filename: String?
    /// ISO instant of the soft delete.
    public let deletedAt: String?
    /// ISO instant from which the daily purge removes the row for good.
    public let purgeAt: String?

    public init(
        id: String,
        kind: DocumentKind = .other,
        title: String? = nil,
        filename: String? = nil,
        deletedAt: String? = nil,
        purgeAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.filename = filename
        self.deletedAt = deletedAt
        self.purgeAt = purgeAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decodeIfPresent(DocumentKind.self, forKey: .kind)) ?? .other
        title = (try? c.decodeIfPresent(String.self, forKey: .title))
        filename = (try? c.decodeIfPresent(String.self, forKey: .filename))
        deletedAt = (try? c.decodeIfPresent(String.self, forKey: .deletedAt))
        purgeAt = (try? c.decodeIfPresent(String.self, forKey: .purgeAt))
    }

    /// The label if set, else the filename, else `nil` (the row then shows the
    /// same "Untitled document" fallback as the vault cards).
    public var resolvedTitle: String? {
        if let title, !title.isEmpty { return title }
        if let filename, !filename.isEmpty { return filename }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, filename, deletedAt, purgeAt
    }
}

/// `data` of `GET /api/documents/inbound/deleted`. The cap (200 rows) rides in
/// the envelope's `meta` and is read through ``ListPage``.
public struct DeletedDocumentList: Decodable, Sendable, Equatable {
    public let documents: [DeletedDocument]
    /// Days a deleted document stays restorable; `nil` when not sent.
    public let graceDays: Int?

    public init(documents: [DeletedDocument], graceDays: Int? = nil) {
        self.documents = documents
        self.graceDays = graceDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? c.decodeIfPresent([Lossy].self, forKey: .documents))
        documents = rows?.compactMap(\.value) ?? []
        graceDays = (try? c.decodeIfPresent(Int.self, forKey: .graceDays))
    }

    private struct Lossy: Decodable {
        let value: DeletedDocument?

        init(from decoder: Decoder) throws {
            value = try? DeletedDocument(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case documents, graceDays
    }
}

/// `data` of `POST /api/documents/inbound/{id}/purge`.
struct DocumentPurgeResult: Decodable, Sendable {
    let id: String?
    let purged: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id))
        purged = (try? c.decodeIfPresent(Bool.self, forKey: .purged)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, purged
    }
}
