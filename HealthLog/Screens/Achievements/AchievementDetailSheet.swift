import SwiftUI

/// Apple-Fitness-Activity-Awards-style badge detail. Presented as `.medium`
/// detent sheet from `AchievementsScreen` when the user taps a medallion.
///
/// **Why this exists (A7 §1.3 user-report #9 — Tap macht nichts):**
/// Achievement medallions need a richer surface to celebrate the unlock
/// (large icon, title, description, earned-date, points, share). Built as a
/// state-only view so snapshots can run on the public contract without
/// dragging the parent screen in.
///
/// POLISH-ACHIEVE (v0.5.5.6):
/// - Earned: glossy gradient ring around hero icon (matches medallion grid),
///   bounce on first-render of `unlockedAt`, **share button** ("Teilen")
///   surfacing a `ShareLink` with localized celebratory copy.
/// - Locked: dotted-ring hero, progress block, no share affordance.
/// - Hidden: opaque "Geheimnisvoller Erfolg" placeholder treatment.
struct AchievementDetailSheet: View {
    let achievement: Achievement
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 72
    @ScaledMetric(relativeTo: .largeTitle) private var iconFrameSize: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            heroIcon
            titleBlock
            descriptionBlock
            progressBlock
            pointsBlock
            Spacer(minLength: 0)
            actionRow
        }
        .padding(.horizontal, HLSpace.xl)
        .padding(.top, HLSpace.xxl)
        .padding(.bottom, HLSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .hlScreenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Swipe down to dismiss."))
    }

    // MARK: - Subviews

    private var heroIcon: some View {
        HStack {
            Spacer()
            ZStack {
                // Base fill — accent gradient for earned, recessed surface
                // for locked / hidden. Mirrors the medallion grid treatment.
                Circle()
                    .fill(heroFill)
                    .frame(width: iconFrameSize, height: iconFrameSize)
                // Ring — glossy gradient when earned (Apple Fitness lighting),
                // dotted stroke when locked (outline-only / not-yet-filled).
                heroRing
                Image(lucide: visibleIconName)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(
                        size: iconSize,
                        weight: .bold
                    )) // `iconSize` is @ScaledMetric(.largeTitle) — already Dynamic-Type-aware hero medallion glyph, off the HLIconSize
                    // scale by design.
                    .foregroundStyle(achievement.unlocked
                        ? HLAccent.userBrandTint
                        : HLText.tertiary)
                    // v0.5.5.1 — bounce on the moment of unlock (the
                    // `unlockedAt` timestamp flip is the canonical "first
                    // appearance after earning" trigger). Apple's
                    // `symbolEffect(.bounce)` honours
                    // `accessibilityReduceMotion` internally so we don't
                    // need to gate the modifier ourselves.
                    .symbolEffect(.bounce, value: achievement.unlockedAt)
            }
            .shadow(
                color: achievement.unlocked && !reduceTransparency
                    ? HLAccent.userBrandTint.opacity(0.22)
                    : Color.clear,
                radius: 14,
                x: 0,
                y: 6
            )
            Spacer()
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var heroRing: some View {
        if achievement.unlocked {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            HLAccent.userBrandTint,
                            HLAccent.userBrandTint.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 4
                )
                .frame(width: iconFrameSize, height: iconFrameSize)
        } else {
            Circle()
                .strokeBorder(
                    HLColor.separator,
                    style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                )
                .frame(width: iconFrameSize, height: iconFrameSize)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(visibleTitle)
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.leading)
            if achievement.unlocked, let earnedAt = achievement.unlockedAt {
                Text("Earned on \(HLDateFormat.date(earnedAt, style: .long))")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            } else if achievement.isHiddenPlaceholder {
                Text("Mysterious achievement — discover it")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            } else {
                Text("Not unlocked yet")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var descriptionBlock: some View {
        if !achievement.isHiddenPlaceholder {
            Text(achievement.description)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var progressBlock: some View {
        if !achievement.unlocked, !achievement.isHiddenPlaceholder, achievement.progress > 0 {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack {
                    Text("Progress")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    Spacer()
                    Text(progressPercentLabel)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                }
                ProgressView(value: achievement.progress)
                    .progressViewStyle(.linear)
                    .animation(reduceMotion ? nil : HLMotion.progress, value: achievement.progress)
                // v0.16 Build 7 / item 7.4 — absolute progress ("12 / 30 days"),
                // web parity with `formatMetric(current, target)`. Uses the
                // tolerant `current`/`target`/`format` fields; hidden when the
                // server omits them (older payloads → percent-only rail above).
                if let absoluteProgressLabel {
                    Text(absoluteProgressLabel)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(HLSpace.md)
            .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        }
    }

    @ViewBuilder
    private var pointsBlock: some View {
        if let points = achievement.points, points > 0 {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: "star.circle.fill")
                    .foregroundStyle(HLText.secondary)
                    .font(.hlIcon(HLIconSize.lg, weight: .bold))
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text("Points")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    Text("\(points) points")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                }
                Spacer()
            }
            .padding(HLSpace.md)
            .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        }
    }

    /// Bottom action row — `Teilen` only for earned achievements (sharing
    /// locked / hidden cards would be weird). v0.6.1 Y2 — dropped the
    /// always-present `Schließen` button per docs/design-handbook-v1.md
    /// §2.6 (Home-Compliance pattern). Drag-down dismisses the sheet;
    /// the share-link stays because it's a functional action, not chrome.
    @ViewBuilder
    private var actionRow: some View {
        if achievement.unlocked {
            shareButton
        }
    }

    private var shareButton: some View {
        ShareLink(item: shareMessage) {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(.hlHeadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLSpace.sm)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("AchievementDetailSheet.share")
    }

    // MARK: - Derived

    private var heroFill: AnyShapeStyle {
        if achievement.unlocked {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        HLAccent.userBrandTint.opacity(0.28),
                        HLAccent.userBrandTint.opacity(0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(HLSurface.tertiary)
    }

    /// Falls back to `Trophy` if the server omitted iconName entirely.
    private var visibleIconName: String {
        if achievement.isHiddenPlaceholder {
            return "HelpCircle"
        }
        return achievement.iconName ?? "Trophy"
    }

    private var visibleTitle: String {
        if achievement.isHiddenPlaceholder {
            return String(localized: "Secret achievement")
        }
        return achievement.title
    }

    private var progressPercentLabel: String {
        HLNumberFormat.percent(Int(round(achievement.progress * 100)))
    }

    /// v0.16 Build 7 / item 7.4 — "12 / 30 days" absolute progress from the
    /// server's `current`/`target`, formatted per `format` (mirrors the web
    /// `formatMetric`). `nil` when the payload omits the pair (pre-parity
    /// server) so the sheet degrades to the percent rail alone.
    private var absoluteProgressLabel: String? {
        guard let current = achievement.current,
              let target = achievement.target, target > 0 else { return nil }
        let currentText = current.formatted(.number.precision(.fractionLength(0)))
        let targetText = target.formatted(.number.precision(.fractionLength(0)))
        switch achievement.format {
        case .percent:
            return "\(HLNumberFormat.percent(current)) / \(HLNumberFormat.percent(target))"
        case .days:
            return String(localized: "\(currentText) / \(targetText) days")
        case .count, .none:
            return "\(currentText) / \(targetText)"
        }
    }

    /// Celebratory share text. Includes the title + points so the recipient
    /// sees what was unlocked at a glance. Format mirrors HealthLog's
    /// playful operator voice — `🏆 HealthLog: ...`
    private var shareMessage: String {
        if let points = achievement.points, points > 0 {
            return String(
                localized: "achievement.share.withPoints \(achievement.title) \(points)"
            )
        }
        return String(
            localized: "achievement.share.noPoints \(achievement.title)"
        )
    }

    private var accessibilityLabel: Text {
        var parts: [String] = []
        parts.append(String(localized: "achievement.a11y.prefix"))
        parts.append(visibleTitle)
        if achievement.unlocked, let earnedAt = achievement.unlockedAt {
            parts.append(String(
                localized: "Earned on \(HLDateFormat.date(earnedAt, style: .long))"
            ))
        } else if !achievement.isHiddenPlaceholder {
            parts.append(String(localized: "Not unlocked yet"))
        }
        if let points = achievement.points, points > 0 {
            parts.append("\(points) points")
        }
        return Text(parts.joined(separator: ". "))
    }
}

#Preview("Unlocked — Trophy") {
    AchievementDetailSheet(
        achievement: Achievement(
            id: "intake-total-50",
            key: "intake-total-50",
            title: "Konsequenter Pillenfreund",
            description: "Du hast 50 Medikamenten-Einnahmen erfasst — Beständigkeit zahlt sich aus.",
            iconName: "Pill",
            unlocked: true,
            unlockedAt: Date(timeIntervalSince1970: 1_716_800_000),
            progress: 1.0,
            points: 60
        ),
        onDismiss: {}
    )
}

#Preview("Locked — partial progress") {
    AchievementDetailSheet(
        achievement: Achievement(
            id: "bp-50",
            key: "bp-50",
            title: "Vitalwerte-Profi",
            description: "Erfasse 50 Blutdruck-Messungen.",
            iconName: "Heart",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.42,
            points: 90
        ),
        onDismiss: {}
    )
}

#Preview("Hidden placeholder") {
    AchievementDetailSheet(
        achievement: Achievement(
            id: "hidden-night-owl",
            key: "hidden-night-owl",
            title: "achievements.hiddenCard.title",
            description: "achievements.hiddenCard.description",
            iconName: "HelpCircle",
            unlocked: false,
            unlockedAt: nil,
            progress: 0,
            points: 25
        ),
        onDismiss: {}
    )
}
