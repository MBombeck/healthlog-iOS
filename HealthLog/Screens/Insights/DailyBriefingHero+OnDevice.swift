import Foundation
import SwiftUI

/// Convenience renderer that prefers the on-device briefing path and falls
/// back to a caller-supplied server `DailyBriefing` when the device is
/// ineligible / the feature flag is off / the safety filter refused / the
/// FoundationModels framework is unavailable at compile time.
///
/// Cached per-day in `UserDefaults` so the on-device model is invoked at
/// most once per calendar day per locale. Cache is keyed by the local
/// `yyyy-MM-dd` date in the user's current timezone.
public struct OnDeviceBriefingHero: View {
    public let measurements: [Measurement]
    public let healthScore: HealthScore?
    public let serverFallback: DailyBriefing?
    public let style: DailyBriefingHero.Style
    public let locale: Locale
    /// v0.10.0 W-Insights (R2 §6.1) — whole-card tap (opens AskCoach). nil →
    /// non-tappable. Forwarded onto every non-empty arm.
    public let onTap: (() -> Void)?
    /// v0.5.4 BF-1 — local-data inputs for the Statistik-Mode floor. When
    /// the on-device + server-AI paths both fail to produce a briefing,
    /// the hero composes one from mood-entries + medication-compliance +
    /// measurement-counts so the operator never sees a stuck "keine
    /// Daten" surface on a device that actually has data sitting in the
    /// local stores.
    public let moodEntries: [MoodEntry]
    public let compliance: ComplianceSnapshotInput?
    /// Injected service. Default value reads the legacy UserDefaults
    /// flags; AppContainer-instantiated callers should pass a service
    /// constructed with `FeatureFlagsStore.liveService()` so the
    /// on-device path honours server-deployed flag state (F-1, R5).
    public let service: OnDeviceBriefingService
    /// I-3 ITEM 3 — when the user has **server AI active** (`aiMode == .online`)
    /// the server-generated briefing is richer than the on-device / Statistik
    /// arm ("doppelt gemoppelt"), so the resolution ladder PREFERS the server
    /// `serverFallback` when it is available, falling back to on-device only when
    /// the server arm produced nothing. Defaults `false` so every existing caller
    /// keeps the on-device-first ladder (RA2 §6 privacy default). The flag never
    /// fabricates: with no server briefing it degrades to the on-device ladder.
    public let preferServer: Bool

    @State private var resolved: ResolvedBriefing = .loading
    /// v0.9.0 W2 — reduce-motion drops the skeleton→content fade to an
    /// instant swap (RA4: animations reduce-motion-aware; 200-300 ms
    /// perceptual budget honoured when motion is allowed).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        measurements: [Measurement],
        healthScore: HealthScore?,
        serverFallback: DailyBriefing?,
        moodEntries: [MoodEntry] = [],
        compliance: ComplianceSnapshotInput? = nil,
        style: DailyBriefingHero.Style = .full,
        locale: Locale = .current,
        service: OnDeviceBriefingService = OnDeviceBriefingService(),
        preferServer: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.measurements = measurements
        self.healthScore = healthScore
        self.serverFallback = serverFallback
        self.moodEntries = moodEntries
        self.compliance = compliance
        self.style = style
        self.locale = locale
        self.service = service
        self.preferServer = preferServer
        self.onTap = onTap
    }

    public var body: some View {
        Group {
            switch resolved {
            case .loading:
                ProgressView()
                    .padding()
                    .accessibilityLabel(Text(String(localized: "Daily briefing is being prepared")))
            case let .onDevice(mapped):
                // v0.9.0 W2 — provenance ON: genuinely the on-device
                // FoundationModels output (RA2 §6 honesty). v0.10.0 — loud
                // labeled row + whole-card tap (R2 §6.1 Zone 1).
                DailyBriefingHero(
                    briefing: mapped,
                    style: style,
                    showsOnDeviceProvenance: true,
                    provenance: .onDevice,
                    onTap: onTap
                )
            case let .server(server, provenance):
                // Server / Statistik-Mode-floor arm — honest provenance row,
                // never the on-device claim.
                DailyBriefingHero(
                    briefing: server,
                    style: style,
                    showsOnDeviceProvenance: false,
                    provenance: provenance,
                    onTap: onTap
                )
            case .empty:
                EmptyView()
            }
        }
        // v0.5.3 D1 — keying on the cache day alone meant the resolve
        // never re-ran when measurements arrived after first paint.
        // Operator saw "keine Daten" because the hero captured an empty
        // `measurements` array at first body-eval (before
        // `measurementsStore.load()` finished) and SwiftUI's `task(id:)`
        // refused to restart on the same calendar day. Including
        // `inputSignature` re-runs whenever the input data set actually
        // changes shape (count + healthScore presence + a coarse content
        // hash) without burning extra on-device model calls in steady
        // state.
        .task(id: TaskKey(cacheKey: cacheKey, inputSignature: inputSignature)) {
            await resolve()
        }
    }

    /// v0.9.0 W2 — skeleton→content fade. `nil` under reduce-motion so the
    /// arm swaps instantly; otherwise a 200 ms ease-in-out inside the
    /// perceptual budget (PROJECT_GUIDE.md Marathon discipline 200-300 ms).
    private var resolveFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private func resolve() async {
        // v0.5.4 BF-1 — the Statistik-Mode floor is the FIRST candidate
        // we keep on hand for the empty-AI-paths case. Composed locally
        // from measurements + mood + medication-compliance, it always
        // shows meaningful content when any of those buckets is non-
        // empty, regardless of whether Apple Intelligence is configured
        // or a server-AI provider was set up on the user account.
        //
        // Previous attempts (v0.5.1 B1, v0.5.3 D1) treated the floor as
        // a last-resort curated digest of measurements only. The operator
        // on a fresh device with HK pulling data + meds scheduled +
        // mood logged still landed on "keine Daten" when neither AI
        // path produced a payload. The floor now stitches all three
        // local sources and the hero is guaranteed visible whenever
        // the device actually has data.
        let statistikFloor = StatistikModeBriefingService.compose(
            measurements: measurements,
            moodEntries: moodEntries,
            compliance: compliance,
            healthScore: healthScore,
            locale: locale
        )

        // v0.5.4 BF-1 — fast path #1 (REWRITTEN): truly-empty inputs (no
        // measurements, no mood, no compliance, no health-score) → render
        // server fallback if available, otherwise `.empty`. Previously this
        // gate only consulted measurements + healthScore; with the floor
        // now eating mood + compliance too the early-return relies on
        // `statistikFloor == nil` (its precondition is "every bucket
        // empty"), so we just check that.
        // v0.5.4 BF-1 — diagnostic trail. Operator can watch the resolve
        // ladder in Console.app on a real device to confirm which arm
        // surfaces (on-device / server / Statistik-Mode floor / empty).
        // No PII in the log — only counts + flags.
        let measurementsCount = measurements.count
        let moodCount = moodEntries.count
        let hasCompliance = compliance != nil
        let hasHealthScore = healthScore != nil
        let hasFloor = statistikFloor != nil
        let hasServer = serverFallback != nil
        // Counts + booleans only — operator-grade, no user content.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.ui.notice(
            // swiftlint:disable:next line_length
            "briefing.resolve start m=\(measurementsCount, privacy: .public) mood=\(moodCount, privacy: .public) compliance=\(hasCompliance, privacy: .public) hs=\(hasHealthScore, privacy: .public) floor=\(hasFloor, privacy: .public) server=\(hasServer, privacy: .public) preferServer=\(preferServer, privacy: .public)"
        )

        // I-3 ITEM 3 — server AI active → the server briefing outranks the
        // on-device / Statistik arm. The on-device path stays the honest
        // FALLBACK (when the server produced nothing), so nothing is fabricated:
        // we only short-circuit to the server arm when one actually exists.
        if preferServer, let serverFallback {
            HLLog.ui.notice("briefing.resolve → server (preferred, AI online)")
            withAnimation(resolveFade) {
                resolved = .server(serverFallback, .account)
            }
            return
        }

        guard statistikFloor != nil else {
            HLLog.ui.notice("briefing.resolve → empty/serverFallback (no local data)")
            withAnimation(resolveFade) {
                resolved = serverFallback.map { .server($0, .account) } ?? .empty
            }
            return
        }

        if let cached = OnDeviceBriefingCache.shared.read(for: cacheKey) {
            HLLog.ui.notice("briefing.resolve → cache-hit on-device")
            withAnimation(resolveFade) {
                resolved = .onDevice(cached)
            }
            return
        }
        let outcome = await service.generate(
            measurements: measurements,
            healthScore: healthScore,
            locale: locale
        )
        // v0.5.x I-4 — smooth the skeleton→content transition so the
        // briefing doesn't pop into place when the on-device model lands
        // (perceptual-budget 200-300 ms, PROJECT_GUIDE.md Marathon discipline).
        //
        // v0.5.4 BF-1 — resolution ladder (in order of preference):
        // 1. On-device generated briefing (Apple Intelligence, iOS 26+).
        // 2. Server-AI briefing payload (DailyBriefingStore).
        // 3. Statistik-Mode floor (this commit) — composed from local
        //    measurements + mood + medication-compliance. The floor is
        //    ALWAYS present when any of those buckets is non-empty —
        //    operator no longer sees "keine Daten" on a populated device.
        //
        // v0.5.3 D1 — cache invariant kept: only persist on-device output
        // when measurements is non-empty so a transient empty first-paint
        // never poisons the calendar day.
        let reason = outcome.fallbackReason?.rawValue ?? "ok"
        // v0.5.4.1 — strict floor invariant. When the on-device path
        // returned a payload but the payload is empty/trivial (no
        // findings, summary too short to be a sentence) we PREFER the
        // Statistik-Mode floor over showing a near-empty hero. This is
        // the lesson from the operator walkthrough: a "succeeds with
        // garbage" outcome from the model would otherwise paint chips
        // that the user reads as raw debug noise.
        let onDevice = outcome.briefing
        let onDeviceIsUseful = isUseful(briefing: onDevice)
        withAnimation(resolveFade) {
            if let onDevice, onDeviceIsUseful {
                let mapped = Self.mapToServerShape(onDevice)
                if !measurements.isEmpty {
                    OnDeviceBriefingCache.shared.write(mapped, for: cacheKey)
                }
                resolved = .onDevice(mapped)
                // Fallback-reason enum raw value — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.ui.notice("briefing.resolve → on-device (\(reason, privacy: .public))")
            } else if let statistikFloor {
                // v0.5.4.1 — Statistik-Mode floor now beats the server
                // fallback in the ladder. The local floor is always
                // grounded in the operator's data (measurements +
                // mood + compliance + health-score) whereas the server
                // fallback is the pre-AI legacy `DailyBriefing` snapshot
                // which on a fresh device often lags reality.
                resolved = .server(statistikFloor, .localData)
                // Fallback-reason enum raw value + boolean — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.ui.notice(
                    "briefing.resolve → floor (reason=\(reason, privacy: .public) useful=\(onDeviceIsUseful, privacy: .public))"
                )
            } else if let serverFallback {
                resolved = .server(serverFallback, .account)
                // Fallback-reason enum raw value — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.ui.notice("briefing.resolve → server fallback (on-device reason=\(reason, privacy: .public))")
            } else {
                resolved = .empty
                HLLog.ui.notice("briefing.resolve → empty (no path produced output)")
            }
        }
    }

    /// v0.5.4.1 — predicate guarding the on-device output. Useful means:
    /// summary has at least one short sentence of real text AND the
    /// summary does not look like an identifier echo. Empty key-findings
    /// are tolerated (the floor handles the chip strip).
    private func isUseful(briefing: OnDeviceBriefing?) -> Bool {
        guard let briefing else { return false }
        let trimmed = briefing.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        if trimmed.range(of: #"on_device_\d+"#, options: .regularExpression) != nil { return false }
        return true
    }

    private var cacheKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let day = formatter.string(from: Date())
        let lang = locale.language.languageCode?.identifier ?? "de"
        return "ondevice_briefing.\(day).\(lang)"
    }

    /// v0.5.3 D1 — coarse shape-signature of the input dataset. Re-runs
    /// the resolve task when count rolls over from 0 → N or when the
    /// healthScore presence flips. Intentionally NOT keyed on the full
    /// measurement set (that would re-invoke the on-device model on every
    /// HK sample arrival mid-session). The signature captures the
    /// boundary transitions that matter for first-paint correctness.
    ///
    /// v0.5.4 BF-1 — extended to factor in mood-entry presence + medication
    /// compliance shape so the hero re-paints when the operator logs mood
    /// or completes a med intake mid-session. Without these the
    /// Statistik-Mode floor would never refresh after first paint even
    /// when its underlying input changed.
    private var inputSignature: String {
        let measurementBucket = switch measurements.count {
        case 0: "0"
        case 1 ..< 10: "low"
        case 10 ..< 100: "med"
        default: "high"
        }
        let score = healthScore.map { "\($0.score)" } ?? "nil"
        let moodBucket = moodEntries.isEmpty ? "0" : "\(moodEntries.count)"
        let complianceBucket = compliance.map { "\($0.takenToday)/\($0.scheduledToday)" } ?? "nil"
        // I-3 ITEM 3 — re-resolve when the server-preference or the server arm's
        // presence flips (e.g. the server briefing lands after first paint, or
        // the user just turned server AI on), so the ladder re-evaluates.
        let serverArm = "\(preferServer ? 1 : 0)\(serverFallback != nil ? 1 : 0)"
        return "\(measurementBucket).\(score).m\(moodBucket).c\(complianceBucket).s\(serverArm)"
    }

    /// Internal `task(id:)` key that combines the calendar-day cache key
    /// with the input-data signature. Hashable struct so SwiftUI can
    /// diff it for free.
    private struct TaskKey: Hashable {
        let cacheKey: String
        let inputSignature: String
    }

    /// Maps an `OnDeviceBriefing` to the existing server-shaped `DailyBriefing`
    /// so `DailyBriefingHero` renders both with identical view code (R4 §2.6
    /// isomorphism).
    ///
    /// v0.5.1-A B1: `sourceMetric` previously leaked the synthetic
    /// `on_device_0_7d` token into the rendered chip; the field is now a
    /// stable empty string so the chip surface only carries the headline
    /// the model produced.
    static func mapToServerShape(_ on: OnDeviceBriefing) -> DailyBriefing {
        let paragraph = on.summary
        let findings: [KeyFinding] = on.keyFindings.map { headline in
            KeyFinding(
                tone: .info,
                headline: headline,
                detail: headline,
                delta: nil,
                sourceWindow: "7d",
                sourceMetric: ""
            )
        }
        return DailyBriefing(paragraph: paragraph, keyFindings: findings)
    }

    private enum ResolvedBriefing {
        case loading
        case onDevice(DailyBriefing)
        /// v0.10.0 — the non-on-device arm carries its honest provenance so
        /// the hero can render the loud labeled row (R2 §6.1): `.localData` for
        /// the Statistik-Mode floor, `.account` for the server-AI fallback.
        case server(DailyBriefing, DailyBriefingHero.Provenance)
        case empty
    }
}

/// Per-day cache for on-device briefings, keyed by
/// `ondevice_briefing.<yyyy-MM-dd>.<lang>`. Entries auto-expire on key
/// change (next-day rollover) — `write` keeps only the most-recent key.
///
/// **v0.9.0 — storage moved off `UserDefaults` to a file-protected JSON
/// file** (`Application Support/HealthLog/Briefing/briefing-cache.json`) with
/// `.completeUntilFirstUserAuthentication` protection, matching the Outbox /
/// GLP1 / HKStats stores. The project rule (PROJECT_GUIDE.md) is: no health-derived
/// data in `UserDefaults`; the briefing text is derived from health
/// measurements, so it belongs in the protected app store. A one-time
/// migration drops any legacy `ondevice_briefing.*` `UserDefaults` keys.
///
/// QS-1 reconcile: `@unchecked Sendable` with an `NSLock`-guarded barrier
/// around the whole read-modify-write so concurrent `write` / `clearOnLogout`
/// calls can't interleave the load-dict-then-rewrite-file pattern.
final class OnDeviceBriefingCache: @unchecked Sendable {
    static let shared = OnDeviceBriefingCache()
    private let fileURL: URL?
    private let lock = NSLock()
    private static let legacyPrefix = "ondevice_briefing."

    /// Designated init resolves the protected on-disk store + runs the
    /// one-time legacy `UserDefaults` migration. The DEBUG `init(directory:)`
    /// is a test seam pointing at a throwaway temp directory.
    private init() {
        fileURL = Self.defaultStoreURL()
        migrateLegacyUserDefaultsIfNeeded()
    }

    #if DEBUG
        init(directory: URL) {
            do {
                try SensitiveDataBackupExclusion.prepareDirectory(at: directory)
                fileURL = directory.appendingPathComponent("briefing-cache.json", isDirectory: false)
            } catch {
                fileURL = nil
            }
        }
    #endif

    func read(for key: String) -> DailyBriefing? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key]
    }

    func write(_ briefing: DailyBriefing, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        // Auto-expire: only the most-recent key survives a write.
        persist([key: briefing])
    }

    /// Drops all cached briefings — called from `AppContainer.handleLocalLogout`
    /// (QC-1 / Arch-H3 reconcile). Previously the cache survived logout,
    /// leaking the previous user's briefing text on the next account that
    /// signed in on the same device.
    func clearOnLogout() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File I/O (caller holds `lock`)

    private func load() -> [String: DailyBriefing] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: DailyBriefing].self, from: data)) ?? [:]
    }

    private func persist(_ entries: [String: DailyBriefing]) {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        do {
            try SensitiveDataBackupExclusion.prepareDirectory(at: dir)
            // Health-derived content at rest → protect until first unlock, the
            // same tier as the Outbox / GLP1 stores (ADR-011/012).
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
    }

    /// One-time sweep of any legacy `ondevice_briefing.*` keys left in
    /// `UserDefaults.standard` by pre-v0.9.0 builds. We don't migrate the
    /// values (a per-day cache is cheap to regenerate); we just clear them so
    /// no health-derived text lingers in the unprotected store.
    private func migrateLegacyUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let dict = defaults.dictionaryRepresentation()
        for key in dict.keys where key.hasPrefix(Self.legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func defaultStoreURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = appSupport
            .appendingPathComponent("HealthLog", isDirectory: true)
            .appendingPathComponent("Briefing", isDirectory: true)
        do {
            try SensitiveDataBackupExclusion.prepareDirectory(at: directory, fileManager: fm)
        } catch {
            return nil
        }
        return directory
            .appendingPathComponent("briefing-cache.json", isDirectory: false)
    }
}
