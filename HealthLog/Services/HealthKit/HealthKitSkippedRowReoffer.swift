import Foundation

/// **Offering refused rows to the server again.**
///
/// A refusal is deterministic for one server and one app mapping; both change
/// over time. So the skip register's rows are offered again:
///
///   * automatically, once per app build — on the first collection pass after
///     an update (a new build can carry a mapping fix, and the server has
///     usually been updated in between);
///   * on demand, from Sync Diagnostics ("Resend skipped").
///
/// The verdict decides what happens to each row: stored (`inserted`, `updated`,
/// `duplicate`) removes it, refused again keeps it with the new reason and this
/// build's stamp, anything else (transport failure, a partial answer) leaves it
/// exactly as it was, so the next pass offers it again.
struct HealthKitSkippedRowReoffer: Sendable {
    struct Summary: Sendable, Equatable {
        let offered: Int
        let stored: Int
        let stillRefused: Int
        /// The upload did not come back with a verdict; nothing changed.
        let transportFailed: Bool

        static let nothingToOffer = Summary(offered: 0, stored: 0, stillRefused: 0, transportFailed: false)
    }

    let register: HealthKitSkippedRowRegister
    /// The batch POST, already bound to the admitted account.
    let upload: @Sendable ([HealthKitBatchEntryDTO]) async throws -> [BatchUploadOutcome]

    /// - Parameter force: offer every row, not only the ones this build has not
    ///   offered yet (the manual path).
    func run(ownerID: String, build: String, force: Bool, at now: Date = Date()) async -> Summary {
        let due = force
            ? await register.measurementRows(ownerID: ownerID)
            : await Self.merged(
                register.rowsDue(ownerID: ownerID, build: build),
                register.unansweredRowsDue(ownerID: ownerID, at: now)
            )
        guard !due.isEmpty else { return .nothingToOffer }

        let outcomes: [BatchUploadOutcome]
        do {
            // Rows refused under a name the server never mapped
            // (the noise event before REG) are offered under its name.
            outcomes = try await upload(due.compactMap(\.entry).map { $0.withServerWireName() })
        } catch {
            // No verdict: unanswered rows wait longer before the next offer.
            let unanswered = Set(due.filter(\.awaitsVerdict).map(\.id))
            try? await register.noteOfferWithoutVerdict(ids: unanswered, ownerID: ownerID, at: now)
            return Summary(offered: due.count, stored: 0, stillRefused: 0, transportFailed: true)
        }

        var stored = Set<String>()
        var refused: [HealthKitSkippedEntry] = []
        for outcome in outcomes {
            for verdict in outcome.rowVerdicts {
                let entry = outcome.chunk[verdict.index]
                if verdict.isStored {
                    stored.insert(entry.externalId)
                } else if verdict.status == .skipped {
                    refused.append(
                        HealthKitSkippedEntry(entry: entry, reason: verdict.reason ?? "unknown", detail: verdict.detail)
                    )
                }
            }
        }
        do {
            try await register.applyReoffer(
                stored: stored,
                refused: refused,
                ownerID: ownerID,
                build: build,
                at: now
            )
        } catch {
            // The server already has the stored rows; a failed local write only
            // means they are offered once more and come back `duplicate`.
            HLLog.healthKit.error("skip register re-offer write failed — rows are offered again next pass")
        }
        return Summary(offered: due.count, stored: stored.count, stillRefused: refused.count, transportFailed: false)
    }
}

extension HealthKitSkippedRowReoffer {
    /// The build's due rows and the unanswered rows whose wait is over, each once.
    static func merged(_ first: [HealthKitSkippedRow], _ second: [HealthKitSkippedRow]) -> [HealthKitSkippedRow] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.id).inserted }
    }
}

/// What Sync Diagnostics shows about the skip register for the signed-in
/// account.
struct HealthKitSkippedRowSnapshot: Sendable, Equatable {
    let rows: [HealthKitSkippedRow]
    let overflow: Int

    var countsByIdentifier: [String: Int] {
        rows.reduce(into: [:]) { $0[$1.hkIdentifier, default: 0] += 1 }
    }
}

/// The seam Sync Diagnostics reaches the register through.
///
/// Installed by the composition root together with the app-owned collection,
/// because that is where the admission (owner + bearer) and the uploader live.
/// Before installation — and while signed out — both calls answer `nil`: there
/// is no account whose rows could be shown or sent.
@MainActor
enum HealthKitSkippedRowAccess {
    private static var snapshotProvider: (@Sendable () async -> HealthKitSkippedRowSnapshot?)?
    private static var resender: (@Sendable () async -> HealthKitSkippedRowReoffer.Summary?)?

    static func install(
        snapshot: @escaping @Sendable () async -> HealthKitSkippedRowSnapshot?,
        resend: @escaping @Sendable () async -> HealthKitSkippedRowReoffer.Summary?
    ) {
        snapshotProvider = snapshot
        resender = resend
    }

    static func snapshot() async -> HealthKitSkippedRowSnapshot? {
        guard let snapshotProvider else { return nil }
        return await snapshotProvider()
    }

    static func resend() async -> HealthKitSkippedRowReoffer.Summary? {
        guard let resender else { return nil }
        return await resender()
    }
}
