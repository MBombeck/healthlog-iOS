import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// What one "Send routes of older workouts" pass did. Counts only, never a
/// position or a time. Outside the HealthKit guard so the settings model can
/// hold it on every platform.
struct WorkoutRouteBackfillSummary: Sendable, Equatable {
    /// Workouts of the window that were looked at.
    var checked = 0
    /// Workouts that went out with their route.
    var sent = 0
    /// Workouts the server attached the route to (`enriched`).
    var attached = 0
}

/// Why a pass stopped before its end.
enum WorkoutRouteBackfillFailure: Error, Sendable, Equatable {
    /// The switch was turned off (or the account changed) during the pass.
    case notAllowed
    /// Apple Health did not hand out the workouts of the window.
    case read
    /// A batch did not reach the server; it waits in the outbox like any
    /// other workout batch.
    case upload
}

#if canImport(HealthKit)

    /// **POLISH-B B10 (1.5, #163 B6, server v1.47.1) — routes for
    /// workouts that are already stored.**
    ///
    /// Until v1.47.0 the workout batch kept a route only for a workout it
    /// inserted, so the opt-in helped new workouts only (ROUTES, deviation 1).
    /// From v1.47.1 an entry that matches a stored workout without a track
    /// attaches the route it carries and reports `enriched`; a workout that
    /// already has a track keeps it, and with routes off nothing is stored.
    ///
    /// This is the one explicit pass that uses it: started only by a tap
    /// under the route switch, only while the opt-in is on (asked again before
    /// every read and every batch), only on a server known to be v1.47.1 or
    /// newer, and bounded: the workouts that started in the last 12 months, at
    /// most ``maxWorkouts`` of them, newest first. Each workout is mapped the
    /// way the importer maps it (same `externalId`, so the server matches it),
    /// without a heart-rate series, and sent with its route in the batches
    /// `WorkoutIngestDTO.uploadChunks` cuts (at most 10 workouts and 20 000
    /// route points each, well under the 5 MB body ceiling). The wire gate in
    /// `WorkoutsRepository` still strips every route if the switch closes.
    struct WorkoutRouteBackfill: Sendable {
        static let minimumServerVersion = "1.47.1"
        /// The window: workouts that started in the last 12 months.
        static let lookbackMonths = 12
        /// Upper bound on the workouts one pass reads.
        static let maxWorkouts = 400

        /// Workouts that started on or after `since`, newest first, at most
        /// `limit`.
        let workouts: @Sendable (_ since: Date, _ limit: Int) async throws -> [HKWorkout]
        /// The route read with its time bound and the opt-in check.
        let routes: WorkoutRouteAttachment
        /// One batch to `POST /api/workouts/batch`, under the account's lease.
        let upload: @Sendable ([WorkoutIngestDTO]) async throws -> WorkoutBatchResponseDTO
        var now: @Sendable () -> Date = Date.init

        /// Offered only on a server known to attach routes to stored
        /// workouts (rule 10: unknown means no).
        static func serverSupportsBackfill(defaults: UserDefaults = .standard) -> Bool {
            KnownServerVersion.isAtLeast(minimumServerVersion, defaults: defaults)
        }

        static func windowStart(now: Date, calendar: Calendar = .current) -> Date {
            calendar.date(byAdding: .month, value: -lookbackMonths, to: now)
                ?? now.addingTimeInterval(-365 * 86400)
        }

        func run() async throws -> WorkoutRouteBackfillSummary {
            guard routes.isAllowed() else { throw WorkoutRouteBackfillFailure.notAllowed }
            let since = Self.windowStart(now: now())
            let found: [HKWorkout]
            do {
                found = try await workouts(since, Self.maxWorkouts)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw WorkoutRouteBackfillFailure.read
            }
            var summary = WorkoutRouteBackfillSummary()
            var pending: [WorkoutIngestDTO] = []
            for workout in found.prefix(Self.maxWorkouts) where !WorkoutHealthKitMapping.isOwnEcho(workout) {
                try Task.checkCancellation()
                guard routes.isAllowed() else { throw WorkoutRouteBackfillFailure.notAllowed }
                summary.checked += 1
                guard let dto = await WorkoutHealthKitMapping.ingestDisposition(from: workout).dto else { continue }
                let result = try await routes.attach(to: dto, of: workout, notBefore: since)
                guard case .attached = result.outcome else { continue }
                pending.append(result.dto)
                if pending.count >= WorkoutIngestDTO.maxWorkoutsPerSeriesBatch {
                    try await send(pending, into: &summary)
                    pending = []
                }
            }
            if !pending.isEmpty {
                try await send(pending, into: &summary)
            }
            return summary
        }

        private func send(_ dtos: [WorkoutIngestDTO], into summary: inout WorkoutRouteBackfillSummary) async throws {
            for chunk in WorkoutIngestDTO.uploadChunks(dtos) {
                guard routes.isAllowed() else { throw WorkoutRouteBackfillFailure.notAllowed }
                let response: WorkoutBatchResponseDTO
                do {
                    response = try await upload(chunk)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw WorkoutRouteBackfillFailure.upload
                }
                summary.sent += chunk.count
                summary.attached += response.entries.filter { $0.status == .enriched }.count
            }
        }
    }

    extension WorkoutRouteBackfill {
        /// Production wiring: Apple Health for the workouts and their routes,
        /// the account-leased workout upload.
        static func live(
            store: HKHealthStore,
            repository: WorkoutsRepository,
            ownerUserID: String
        ) -> WorkoutRouteBackfill {
            WorkoutRouteBackfill(
                workouts: { since, limit in
                    let descriptor = HKSampleQueryDescriptor(
                        predicates: [.workout(HKQuery.predicateForSamples(withStart: since, end: nil))],
                        sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                        limit: limit
                    )
                    return try await descriptor.result(for: store)
                },
                routes: .live(store: store, ownerUserID: ownerUserID),
                upload: { chunk in
                    try await repository.uploadBatch(chunk, ownerUserID: ownerUserID)
                }
            )
        }
    }

#endif
