import Foundation

/// The archive a document can be opened in, and where (#187).
public struct DocumentSourceLink: Equatable, Sendable {
    public enum Archive: String, Sendable {
        case paperless = "PAPERLESS"
        case papra = "PAPRA"

        /// The product's own name, the same in every language.
        public var displayName: String {
            switch self {
            case .paperless: "Paperless-ngx"
            case .papra: "Papra"
            }
        }
    }

    public let archive: Archive
    public let url: URL

    /// `nil` unless the system is Paperless-ngx or Papra and the address is
    /// an absolute http(s) URL with a host.
    public init?(system: String?, url raw: String?) {
        guard let system, let archive = Archive(rawValue: system.uppercased()),
              let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        self.archive = archive
        self.url = url
    }
}
