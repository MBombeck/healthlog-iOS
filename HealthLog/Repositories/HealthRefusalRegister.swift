import Foundation

// #115 / 0.3 — the UserDefaults refusal list A3 introduced for nutrients.
//
// INT-A folded every refusal into ONE register, `HealthKitSkippedRowRegister`
// (file-backed, owner-partitioned, bounded, re-offered, wiped at sign-out).
// This generic list survives only so the nutrient rows an earlier build wrote
// under `hl.healthkit.nutrientRefusals.<token>` stay readable: the nutrient
// sweep imports them into the register once and then removes the key
// (`NutrientRefusalRegister.migrate`). Nothing new is written here.

/// One refused row, in whatever shape its sync path needs to name it.
protocol HealthRefusalRecord: Codable, Sendable, Equatable {
    /// A later refusal of the same row replaces the earlier one.
    var refusalKey: String { get }
    /// Ascending order of the stored list; capacity drops the lowest first.
    var refusalSortKey: String { get }
}

/// Per-account, on-device list of refused rows, bounded at `capacity`.
struct HealthRefusalRegister<Record: HealthRefusalRecord>: Sendable {
    let key: String
    let capacity: Int
    private let defaultsProvider: @Sendable () -> UserDefaults

    init(
        keyPrefix: String,
        userID: String?,
        capacity: Int = 400,
        defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
    ) {
        key = keyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userID)
        self.capacity = capacity
        self.defaultsProvider = defaultsProvider
    }

    /// Every recorded refusal, in ``HealthRefusalRecord/refusalSortKey`` order.
    var entries: [Record] {
        guard let data = defaultsProvider().data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// Drops the list (after its rows were imported into the register).
    func clear() {
        defaultsProvider().removeObject(forKey: key)
    }

    func record(_ refusals: [Record]) {
        guard !refusals.isEmpty else { return }
        var byKey: [String: Record] = [:]
        for row in entries + refusals {
            byKey[row.refusalKey] = row
        }
        let kept = byKey.values
            .sorted { $0.refusalSortKey < $1.refusalSortKey }
            .suffix(capacity)
        guard let data = try? JSONEncoder().encode(Array(kept)) else { return }
        defaultsProvider().set(data, forKey: key)
    }
}

// MARK: - How a whole-batch HTTP refusal is read

/// #115 / 0.3 — what a thrown `/api/measurements/batch` call means for the
/// rows it carried.
///
/// A whole-batch 4xx used to be treated like a transport failure: the page
/// went into the outbox, the anchor moved, and the replay met the same 4xx
/// and deleted the row. Three answers replace that:
///
/// * ``refused(reason:)`` — the server refused the batch by a rule it names in
///   `meta.errorCode` (``finalCodes``, from the route at v1.39.1). Final: the
///   rows go into ``HealthKitSkippedRowRegister`` and the window may move.
/// * ``notStored`` — any other 4xx: a validation failure without a code, a
///   module switched off, a route an older server lacks. The server stored
///   nothing and said nothing final. The rows stay where they are (the anchor
///   holds, a queued row parks) until a later answer is either storage or a
///   named refusal.
/// * ``retry`` — transport, 5xx, 408, 429, 401, an in-flight idempotency
///   conflict, and everything this build cannot read as a refusal. The
///   existing durable retry applies.
enum HealthKitBatchRejection: Equatable {
    case refused(reason: String)
    case notStored(status: Int)
    case retry

    /// The named whole-batch refusals of `POST /api/measurements/batch`
    /// (`src/app/api/measurements/batch/route.ts`). At v1.39.0 the Zod failure
    /// (`apiValidationError`) carried no code and stays `notStored` there; from
    /// v1.39.1 it is `measurement.batch.invalid`, final for the batch as sent
    /// (E1). `APIClient` types that one as ``MeasurementBatchInvalid`` so the
    /// uploader can split it; whatever of it reaches this point is refused whole.
    static let finalCodes: Set<String> = [
        "measurement.batch.too_large",
        "measurement.batch.source_not_permitted",
        MeasurementBatchInvalid.code
    ]

    static func classify(_ error: Error) -> Self {
        if let invalid = error as? MeasurementBatchInvalid { return .refused(reason: invalid.reason) }
        guard let error = error as? HLError, !error.shouldPersistToOutbox else { return .retry }
        switch error {
        case let .server(status, code, _) where (400 ..< 500).contains(status):
            if let code, finalCodes.contains(code) { return .refused(reason: "\(status):\(code)") }
            return .notStored(status: status)
        case .moduleDisabled, .aiUnavailable:
            return .notStored(status: 403)
        case .refusedWithReason:
            return .notStored(status: 422)
        default:
            return .retry
        }
    }
}
