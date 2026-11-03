#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation

    extension AppOwnedHealthCollectionCoordinator {
        /// Rounds in a row without a single page before the catch-up stops.
        static let stalledRoundLimit = 3

        /// The history state of every collected type.
        func historyOverview() async -> HealthHistoryOverview? {
            guard let lease = try? admission() else { return nil }
            return await overview(lease: lease, window: cutoff())
        }

        /// "Sync everything now": round after round of live first, then
        /// history with a large allowance, walking every type to the chosen
        /// window (the #128 shortcut is switched off for this account's
        /// partitions), until all of it is done, nothing moves any more, or
        /// the caller's task is cancelled. Progress after every round.
        func runFullCatchUp(
            progress: @escaping @Sendable (HealthHistoryOverview) async -> Void
        ) async -> HealthHistoryCatchUpOutcome {
            guard let lease = try? admission() else { return .notAdmitted }
            let window = cutoff()
            await prepare(lease: lease, window: window)

            let defaults = defaultsProvider()
            let collectable = Self.serverCollectable(Self.collectedTypeIdentifiers)
            let markEverything = fullCatchUpMarker(collectable, lease: lease)
            var quietRounds = 0

            while true {
                if Task.isCancelled { return .cancelled }
                if lease.refusal != nil { return .notAdmitted }
                let historyOrder = HealthCollectionRotation.ordered(
                    collectable,
                    defaults: defaults,
                    key: HealthCollectionRotation.historyOffsetKey
                )
                let results = await SyncTriggerContext.shared.runningPass(.manual) {
                    await collector.collect(
                        typeIdentifiers: collectable,
                        trigger: .manual,
                        notBefore: window,
                        requiring: lease,
                        historyOrder: historyOrder,
                        historyBudget: .fullCatchUpRound,
                        beforeHistory: markEverything
                    )
                }
                Self.advanceHistoryRotation(historyOrder, results: results, defaults: defaults)

                let current = await overview(lease: lease, window: window)
                await progress(current)
                if current.isFinished { return .finished }
                if Task.isCancelled { return .cancelled }

                // A2 (1.4, R3 S6) — progress is a page whose rows were taken.
                // An empty live page, a held page and one parked in the outbox
                // are not; until 1.3.0 they all were, so a catch-up without a
                // server never paused.
                let moved = results.contains(where: AnchoredHealthSampleCollector.madeProgress)
                quietRounds = moved ? 0 : quietRounds + 1
                if quietRounds >= Self.stalledRoundLimit { return .stalled }
            }
        }

        private func overview(lease: HealthSyncAuthenticatedLease, window: Date) async -> HealthHistoryOverview {
            let types = Self.serverCollectable(Self.collectedTypeIdentifiers)
            let keys = types.compactMap { lease.cursorKey(typeIdentifier: $0) }
            // B5 (1.4, R4 2.1) — a walk that reached the readable boundary is
            // done as far as Apple Health lets it go.
            let readable = await collector.readWindows(for: types)
            return await HealthHistoryOverview(
                types: cursors.historyStatus(for: keys, cutoff: window, readable: readable),
                readable: readable
            )
        }

        /// Switches the #128 shortcut off for every partition, after the live
        /// leg of the round has established them.
        private func fullCatchUpMarker(
            _ typeIdentifiers: [String],
            lease: HealthSyncAuthenticatedLease
        ) -> @Sendable () async -> Void {
            let cursors = cursors
            return {
                for typeIdentifier in typeIdentifiers {
                    guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else { continue }
                    await cursors.updateSplit(for: key, requiring: lease) { $0.fullCatchUp = true }
                }
            }
        }
    }

    // MARK: - Process-wide seam

    extension AppOwnedHealthCollection {
        private static var installedOverview: (@Sendable () async -> HealthHistoryOverview?)?
        private static var installedCatchUp: (
            @Sendable (@escaping @Sendable (HealthHistoryOverview) async -> Void) async -> HealthHistoryCatchUpOutcome
        )?

        static func installHistory(
            overview: @escaping @Sendable () async -> HealthHistoryOverview?,
            catchUp: @escaping @Sendable (
                @escaping @Sendable (HealthHistoryOverview) async -> Void
            ) async -> HealthHistoryCatchUpOutcome
        ) {
            installedOverview = overview
            installedCatchUp = catchUp
        }

        /// `nil` while signed out or before the collection is composed.
        static func historyOverview() async -> HealthHistoryOverview? {
            await installedOverview?()
        }

        static func runFullCatchUp(
            progress: @escaping @Sendable (HealthHistoryOverview) async -> Void
        ) async -> HealthHistoryCatchUpOutcome {
            guard let installedCatchUp else { return .notAdmitted }
            return await installedCatchUp(progress)
        }
    }
#endif
