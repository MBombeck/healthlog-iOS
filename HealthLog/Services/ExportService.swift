import Foundation

/// Per-domain CSV export (server-rendered, GDPR Art. 20). Mirrors
/// ``DoctorReportService`` — the canonical "download a server-generated file"
/// shape: build an `APIRequest<Data>` with the right `Accept`, `download`, then
/// hand back the raw bytes + a suggested filename so the UI can persist + share.
///
/// **Why server-only:** the per-domain CSVs are *the server's* canonical export
/// shape (column order, locale, audit columns). There is no on-device source of
/// truth that reproduces them byte-for-byte, so in standalone the calling card
/// degrades to `HLCloudDerivedPlaceholder` rather than inventing a divergent
/// local CSV. The full backup (`SettingsExportScreen`'s full-backup card) and
/// FHIR bundle remain the offline data-portability paths.
///
/// Endpoints (server-confirmed, Bearer-auth, rate-limited 10/h):
/// - `GET /api/export/measurements`
/// - `GET /api/export/mood`
/// - `GET /api/export/medications` (optional `medicationId` / `intake` / `since` / `until`)
public actor ExportService {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// The per-domain CSV surfaces. The `rawValue` is the server path segment.
    public enum Domain: String, Sendable, CaseIterable {
        case measurements
        case mood
        case medications
    }

    /// A downloaded CSV: the raw UTF-8 bytes plus the server-suggested filename
    /// (parsed from `Content-Disposition`, with a deterministic local fallback).
    public struct CSVExport: Sendable {
        public let data: Data
        public let suggestedFilename: String
    }

    /// Download one domain's CSV. `query` carries the optional medication
    /// filters; callers other than medications pass `[]`.
    public func downloadCSV(_ domain: Domain, query: [(String, String)] = []) async throws -> CSVExport {
        let req: APIRequest<Data> = APIRequest(
            method: .get,
            path: "/api/export/\(domain.rawValue)",
            query: query,
            extraHeaders: ["Accept": "text/csv"]
        )
        let (data, response) = try await api.download(req)
        guard response.value(forHTTPHeaderField: "Content-Type")?.contains("text/csv") == true else {
            throw HLError.server(status: response.statusCode, code: nil, message: "Expected text/csv")
        }
        let filename = Self.filename(from: response, domain: domain)
        return CSVExport(data: data, suggestedFilename: filename)
    }

    // MARK: - Full backup (GDPR Art. 20 — JSON / CSV)

    /// The full-backup formats. `rawValue` is the wire `format` value the
    /// server expects in the `POST /api/export` body.
    public enum BackupFormat: String, Sendable, CaseIterable {
        case json
        case csv

        /// The `Accept` header the server keys the response encoding on.
        var acceptHeader: String {
            switch self {
            case .json: "application/json"
            case .csv: "text/csv"
            }
        }
    }

    /// A downloaded full backup: the raw bytes plus the suggested file extension.
    public struct BackupExport: Sendable {
        public let data: Data
        public let fileExtension: String
    }

    /// **AUD-7 H3** — download the full JSON/CSV backup. The endpoint
    /// (`POST /api/export`) and its encoding/`Accept` header used to be built
    /// inline in `SettingsExportScreen` (the last in-view API construction, which
    /// already shipped one wrong-path 404). This actor owns it now, matching the
    /// layering every other export uses.
    ///
    /// Server path is `/api/export` (NOT `/api/data/export` — the dead path that
    /// 404'd, W2a-A2 §8). Shares the `export:<userId>` rate-limit bucket.
    public func downloadFullBackup(_ format: BackupFormat) async throws -> BackupExport {
        struct Body: Encodable {
            let format: String
        }
        let body = try JSONEncoder.hlDefault.encode(Body(format: format.rawValue))
        let req = APIRequest<Data>(
            method: .post,
            path: "/api/export",
            body: body,
            extraHeaders: ["Accept": format.acceptHeader]
        )
        let (data, _) = try await api.download(req)
        return BackupExport(data: data, fileExtension: format.rawValue)
    }

    // MARK: - Encrypted full backup (v1.23 — HLX1 archive)

    /// A downloaded passphrase-encrypted backup: the raw `HLX1` archive bytes
    /// plus the server-suggested filename (with a deterministic `.hlx` fallback).
    public struct EncryptedBackup: Sendable {
        public let data: Data
        public let suggestedFilename: String
    }

    /// Download the passphrase-encrypted full backup — `POST
    /// /api/export/encrypted` with a `{ passphrase }` body returns the same
    /// payload as the plaintext full backup, sealed into an `HLX1` archive
    /// (Argon2id-derived key + AES-256-GCM) under the caller's passphrase. The
    /// binary archive is returned as `application/octet-stream`.
    ///
    /// **Security (server contract):** the passphrase is sent once in the POST
    /// body and never stored — there is NO server-side recovery, so a forgotten
    /// passphrase means the archive is unrecoverable. On an MFA-enrolled account
    /// the server gates this behind a *fresh* second factor (`requireFreshMfaIf`
    /// `Enrolled`) which a Bearer session cannot satisfy — that surfaces as a
    /// typed `HLError.server` the caller renders honestly. Shares the
    /// `export:<userId>` rate-limit bucket (10/h) with every other export.
    public func downloadEncryptedBackup(passphrase: String) async throws -> EncryptedBackup {
        struct Body: Encodable {
            let passphrase: String
        }
        let body = try JSONEncoder.hlDefault.encode(Body(passphrase: passphrase))
        let req = APIRequest<Data>(
            method: .post,
            path: "/api/export/encrypted",
            body: body,
            extraHeaders: ["Accept": "application/octet-stream"]
        )
        // The archive is opaque binary — `download` throws a typed `HLError` on
        // any non-2xx (422 not-configured, 403 MFA step-up, 429 rate-limit), so
        // there is no JSON body to guard on the success path.
        let (data, response) = try await api.download(req)
        let filename = Self.encryptedFilename(from: response)
        return EncryptedBackup(data: data, suggestedFilename: filename)
    }

    /// Parse the server `Content-Disposition` filename for the encrypted archive
    /// (the server stamps `healthlog-backup-<YYYY-MM-DD>.hlx`). Deterministic
    /// local fallback so the share sheet always has a sane title.
    static func encryptedFilename(from response: HTTPURLResponse) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = parseContentDispositionFilename(disposition)
        {
            return parsed
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        return "healthlog-backup-\(stamp).hlx"
    }

    // MARK: - Health-record export package (B2)

    /// A downloaded health-record export: the raw bytes plus the server-suggested
    /// filename (parsed from `Content-Disposition`, with a deterministic fallback).
    public struct PackageExport: Sendable {
        public let data: Data
        public let suggestedFilename: String
    }

    /// Download the unified health-record export **package** — `POST
    /// /api/export/health-record` with `format: "package"` returns an
    /// `application/zip` holding `report.pdf` + `bundle.json` (FHIR R4 Bundle) +
    /// `README.txt` (server v1.12.1 B2). The canonical doctor-handover artefact.
    ///
    /// The request body is built strictly to `exportSelectionSchema` (unknown keys
    /// 422), carrying the **required** v2 `selection` since server v1.32.39 —
    /// the removed grouped `sections` tree this call used to send is what made
    /// every package export 422 (CU-11). Rate limit is the shared
    /// `export:<userId>` bucket, 10/h across PDF + FHIR + package + CSV —
    /// `APIClient` maps 429 to ``HLError/rateLimited``.
    public func downloadHealthRecordPackage(_ request: HealthRecordExportRequest) async throws -> PackageExport {
        let body = try JSONEncoder.hlDefault.encode(request)
        let req: APIRequest<Data> = APIRequest(
            method: .post,
            path: "/api/export/health-record",
            body: body,
            extraHeaders: ["Accept": "application/zip"]
        )
        do {
            let (data, response) = try await api.download(req)
            guard response.value(forHTTPHeaderField: "Content-Type")?.contains("application/zip") == true else {
                throw HLError.server(status: response.statusCode, code: nil, message: "Expected application/zip")
            }
            let filename = Self.packageFilename(from: response)
            return PackageExport(data: data, suggestedFilename: filename)
        } catch {
            // `422 export.selection.unknown_leaf` becomes the typed contract
            // mismatch so the panel can rebuild the scope from a fresh
            // capabilities read; everything else passes through untouched.
            throw HealthRecordExportError.mapped(error)
        }
    }

    /// Parse the server `Content-Disposition` filename (the server stamps
    /// `healthlog-health-record-<YYYY-MM-DD>.zip`). Deterministic local fallback so
    /// the share sheet always has a sane title even if a proxy strips the header.
    static func packageFilename(from response: HTTPURLResponse) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = parseContentDispositionFilename(disposition)
        {
            return parsed
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        return "healthlog-health-record-\(stamp).zip"
    }

    /// Parse the server `Content-Disposition` filename (the server stamps
    /// `healthlog-<domain>-<userId>-<date>.csv`). Falls back to a deterministic
    /// local name so the share sheet always has a sane title even if a proxy
    /// strips the header.
    static func filename(from response: HTTPURLResponse, domain: Domain) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = parseContentDispositionFilename(disposition)
        {
            return parsed
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        return "healthlog-\(domain.rawValue)-\(stamp).csv"
    }

    /// Extract the `filename` token from a `Content-Disposition` header. Handles
    /// both the plain `filename="..."` form and the RFC 5987 `filename*=UTF-8''`
    /// form, preferring the extended form when present.
    static func parseContentDispositionFilename(_ header: String) -> String? {
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }

        // RFC 5987 extended form takes precedence (handles non-ASCII).
        for part in parts where part.lowercased().hasPrefix("filename*=") {
            let value = part.dropFirst("filename*=".count)
            // `UTF-8''<percent-encoded>`
            if let pctStart = value.range(of: "''")?.upperBound {
                let encoded = String(value[pctStart...])
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            }
        }

        for part in parts where part.lowercased().hasPrefix("filename=") {
            var value = String(part.dropFirst("filename=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
