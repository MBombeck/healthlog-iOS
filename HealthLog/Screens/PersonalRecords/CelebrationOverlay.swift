import SwiftUI

/// v0.5.5.6 POLISH-PR — Celebration overlay fired on a new PR.
///
/// Renders a translucent confetti burst over the screen via `Canvas`
/// + 60 deterministic particles. Auto-dismisses after 2.5 s (or
/// instant fade on Reduce Motion). Pairs with a triple-haptic
/// (`.success` + two `.impact(weight: .heavy)` at 80 ms cadence)
/// driven declaratively via `.sensoryFeedback` on appear.
///
/// **Why `Canvas` (not Pow or third-party SDKs):** keeps the bundle
/// dependency-free + Reduce-Motion-respecting + zero allocations on
/// the hot path. The particles are pre-seeded once in `Particle.seed`
/// so each render is a pure draw call.
///
/// **Usage:** present from the screen as a fullscreen overlay:
/// ```swift
/// .overlay {
///     if showCelebration {
///         CelebrationOverlay(record: record) {
///             showCelebration = false
///         }
///     }
/// }
/// ```
struct CelebrationOverlay: View {
    let record: PersonalRecord
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t: Double = 0
    @State private var particles: [Particle] = []
    // Haptic triggers — `.sensoryFeedback` fires once per value change.
    // `successTick` plays the notification-success cue immediately;
    // `heavyTick` is bumped twice at an 80 ms cadence for the two heavy
    // impacts that punctuate the confetti burst.
    @State private var successTick: Int = 0
    @State private var heavyTick: Int = 0
    @State private var celebrationTask: Task<Void, Never>?
    /// Flips true once every particle has outlived its lifespan, freezing the
    /// confetti `TimelineView` so the dead tail of the window isn't redrawn 60×.
    @State private var burstFinished = false

    var body: some View {
        ZStack {
            // Soft dimming so the celebration reads as an overlay
            // moment rather than a flash on top of the record grid.
            // v0.14.8 W2 (Audit §1.1) — `inkScrim` instead of raw black: stays
            // dark in BOTH appearances, no harsh pure-black on the warm canvas.
            HLColor.inkScrim.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            if !reduceMotion {
                confettiCanvas
                    // 08-11 — the confetti is decoration. It carries no
                    // information the announcement does not, and sixty particles
                    // in the reading order would bury the one thing that does.
                    .accessibilityHidden(true)
            }
            announcement
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .sensoryFeedback(.success, trigger: successTick)
        .sensoryFeedback(.impact(weight: .heavy), trigger: heavyTick)
        .onAppear { celebrate() }
        .onDisappear { celebrationTask?.cancel() }
        // 08-11 — ONE element that speaks the record it is celebrating. The
        // label is composed from the same DTO the announcement prints, so
        // VoiceOver hears the metric and the value that are on screen instead
        // of a fixed "something happened" phrase. `.ignore` rather than
        // `.combine`: an explicit label replaces combined children anyway, and
        // saying so is the honest form.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spokenAchievement(for: record.base)))
        // The scrim's tap-to-dismiss is a child gesture, so collapsing the
        // subtree into one element would otherwise leave a VoiceOver user with
        // no way to end the moment early.
        .accessibilityAction(.default) { onDismiss() }
    }

    // MARK: - Spoken and printed content (08-11)

    /// The record's value and unit as one printed string — the figure the
    /// celebration shows and, verbatim, the figure it speaks.
    ///
    /// Locale-aware through ``HLNumberFormat`` (never a hard-coded separator), a
    /// whole number drops its fraction, and a non-finite server value prints the
    /// em dash the rest of the app uses rather than `inf`.
    nonisolated static func valueText(for dto: PersonalRecordDTO) -> String {
        guard dto.value.isFinite else { return "—" }
        let digits = dto.value == dto.value.rounded() ? 0 : 1
        let number = HLNumberFormat.decimal(dto.value, fractionDigits: digits)
        let unit = dto.unit.trimmingCharacters(in: .whitespaces)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// What VoiceOver hears: the localized metric name and the value, in the
    /// order the overlay prints them.
    ///
    /// Pure and `nonisolated` so the contract is checkable without a view tree —
    /// the previous label was a `private` English literal inside `body`, which
    /// is exactly why nothing but a human could check it.
    nonisolated static func spokenAchievement(for dto: PersonalRecordDTO) -> String {
        let metric = MetricTypeLocalisation.label(forType: dto.metricType)
        let value = valueText(for: dto)
        // Both placeholders are Strings by construction (a localized label and a
        // formatted figure), so the catalogue key is `%@ %@` — the same trap
        // `med.inventory.summary` documents.
        return String(localized: "New personal record: \(metric), \(value)")
    }

    /// Longest particle lifespan in the current burst (≤1.6 s by seeding).
    /// Once `elapsed` passes this every particle has fully faded, so the
    /// 60 fps Canvas redraws nothing useful for the remaining ~0.9 s before
    /// auto-dismiss — we freeze the timeline to a static empty Canvas to kill
    /// the 60 fps tail (A7 LOW).
    private var maxParticleLifespan: TimeInterval {
        particles.map(\.lifespan).max() ?? 0
    }

    private var confettiCanvas: some View {
        // `.animation(…, paused:)` stops requesting 60 fps frames once
        // `burstFinished` flips true — every particle has faded, so the dead
        // tail of the window (~0.9 s before auto-dismiss) renders one static
        // empty Canvas instead of 60×/s. `paused` keeps the schedule type
        // (`AnimationTimelineSchedule`) stable so no branch on the schedule.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: burstFinished)) { context in
            Canvas { canvasContext, size in
                let elapsed = max(0, context.date.timeIntervalSince(start))
                // All particles have faded — emit nothing and stop redrawing.
                if elapsed > maxParticleLifespan {
                    if !burstFinished { Task { @MainActor in burstFinished = true } }
                    return
                }
                for particle in particles {
                    let progress = min(1, elapsed / particle.lifespan)
                    let x = particle.origin.x + particle.velocity.x * elapsed * size.width
                    let y = particle.origin.y + particle.velocity.y * elapsed * size.height + 0.5 * 9.8 * elapsed * elapsed * size.height
                    let rect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                    let opacity = 1 - progress
                    canvasContext.fill(
                        Path(ellipseIn: rect),
                        with: .color(particle.tint.opacity(opacity))
                    )
                }
            }
            .ignoresSafeArea()
        }
    }

    private var announcement: some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: "rosette")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(
                    size: 64,
                    weight: .bold
                )) // Celebration-overlay hero medallion glyph — intentionally off the HLIconSize scale (>hero/28pt), a transient
                // full-screen celebration moment with no accompanying scaling body text.
                .foregroundStyle(PersonalRecordKindTint.color(for: record.kind))
                .symbolEffect(.bounce, value: t)
                // 08-11 — a medallion glyph beside its own headline; it says
                // nothing the headline does not.
                .accessibilityHidden(true)
            Text("New record!")
                .font(.hlTitle1)
                .foregroundStyle(HLColor.recordHeroInk)
            Text(MetricTypeLocalisation.label(forType: record.base.metricType))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLColor.recordHeroInk.opacity(0.9))
            // 08-11 — the figure the record is FOR. It was on the card and in
            // the share image but never in the moment itself, so the spoken
            // label had nothing visible to match; now both read the one
            // `valueText` above.
            Text(Self.valueText(for: record.base))
                .font(.hlTitle3.monospacedDigit())
                .foregroundStyle(HLColor.recordHeroInk)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, HLSpace.xl)
        .padding(.vertical, HLSpace.xl)
        .hlGlassBackground(in: RoundedRectangle(cornerRadius: HLRadius.sheet, style: .continuous), fallback: HLSurface.secondary)
    }

    // MARK: - Lifecycle

    @State private var start: Date = .init()

    private func celebrate() {
        start = Date()
        burstFinished = false
        particles = Particle.seed(count: reduceMotion ? 0 : 60, tint: PersonalRecordKindTint.color(for: record.kind))
        // Triple haptic — success → heavy → heavy at 80 ms cadence,
        // driven declaratively via `.sensoryFeedback`. The success cue
        // fires immediately; the two heavy impacts follow on a staggered
        // trigger bump.
        successTick += 1
        celebrationTask?.cancel()
        celebrationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            heavyTick += 1
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            heavyTick += 1
            // Auto-dismiss after the moment settles — operator quote:
            // "lass den Moment wirken, aber halt ihn nicht fest".
            try? await Task.sleep(for: .milliseconds(2340))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
        // Kick the announcement bounce. QoL-A2 (Felt-craft #5) — gated on
        // reduce-motion so the announcement settles instantly when motion
        // is disabled (particles already suppressed above).
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { t += 1 }
    }
}

// MARK: - Particle seeding

/// Pure data-only particle descriptor. The `Canvas` reads these to
/// draw confetti without allocating per frame.
struct Particle: Identifiable, Equatable {
    let id: Int
    let origin: CGPoint
    let velocity: CGPoint
    let tint: Color
    let lifespan: TimeInterval

    /// Deterministic-ish seeding using a `SystemRandomNumberGenerator`.
    /// Particles emit from the top-centre and fall outward; lifespan
    /// 0.7-1.6 s so the burst clears the screen by the auto-dismiss.
    static func seed(count: Int, tint: Color) -> [Particle] {
        guard count > 0 else { return [] }
        var generator = SystemRandomNumberGenerator()
        // v0.6.1 mono refresh — the Dracula confetti palette is replaced
        // with a monochrome ramp + the statusOK success accent so the
        // celebration moment stays inside the new design language.
        let tints: [Color] = [
            tint,
            HLText.primary,
            HLText.primary.opacity(0.7),
            HLText.primary.opacity(0.4),
            HLColor.statusOK,
            HLColor.statusOK.opacity(0.6)
        ]
        return (0 ..< count).map { idx in
            let dx = Double.random(in: -0.35 ... 0.35, using: &generator)
            let dy = Double.random(in: -0.6 ... -0.2, using: &generator)
            return Particle(
                id: idx,
                origin: CGPoint(x: 0.5, y: 0.5),
                velocity: CGPoint(x: dx, y: dy),
                tint: tints.randomElement(using: &generator) ?? tint,
                lifespan: TimeInterval.random(in: 0.7 ... 1.6, using: &generator)
            )
        }
    }
}

#Preview("CelebrationOverlay") {
    let dto = PersonalRecordDTO(
        id: "preview.celebrate",
        userId: "u1",
        metricType: "ACTIVITY_STEPS",
        metricSlot: "Bester Tag",
        direction: .max,
        value: 23412,
        unit: "Steps",
        achievedAt: Date(),
        sourceMeasurementId: nil,
        source: "HEALTHLOG_CLIENT",
        externalId: nil,
        createdAt: Date()
    )
    let record = PersonalRecord(
        id: dto.id,
        base: dto,
        kind: .steps,
        sparklineValues: [],
        peakIndex: nil,
        previousValue: nil,
        bucket: .week,
        impressiveness: 0.95
    )
    return CelebrationOverlay(record: record, onDismiss: {})
        .background(HLSurface.primary)
}
