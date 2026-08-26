import SwiftUI

/// Apple-Fitness-Activity-Awards-style circular medallion for a single
/// achievement. Replaces the legacy chunky `HLCard`-wrapped cell.
///
/// **Earned (`unlocked == true`):**
/// - Filled circle with the accent tint (~24% opacity).
/// - Glossy 3pt gradient ring (accent → accent.opacity(0.45)) running
///   top-leading → bottom-trailing — reads as "lit from above".
/// - Lucide icon at full accent colour, bold.
///
/// **Locked (`unlocked == false`, not hidden):**
/// - Recessed surface fill (`HLSurface.tertiary`).
/// - Dotted-stroke 1.5pt ring at `HLColor.separator` — visually communicates
///   "outline-only / not yet filled".
/// - Dimmed glyph (`HLText.tertiary`).
/// - Long-press shows a "Noch nicht freigeschaltet" tooltip via `.help(_:)`
///   — VoiceOver picks it up as the accessibility-hint.
///
/// **Hidden placeholder (`isHiddenPlaceholder == true`):**
/// - Same dotted-ring as locked.
/// - Icon: `questionmark` glyph (HelpCircle in Lucide-naming).
/// - Title hidden, replaced by localized "Geheim".
///
/// Pulled out so the medallion itself stays state-pure (used in previews +
/// snapshot tests without a Store).
struct AchievementMedallion: View {
    let achievement: Achievement

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 72pt at Default Dynamic-Type, scales with Accessibility sizes.
    @ScaledMetric(relativeTo: .title2) private var medallionSize: CGFloat = 72
    @ScaledMetric(relativeTo: .title2) private var glyphSize: CGFloat = 28

    var body: some View {
        VStack(spacing: HLSpace.xs) {
            medallion
            label
        }
        .frame(maxWidth: .infinity)
        // Long-press tooltip surfaces locked-state context without
        // cluttering the visual; VoiceOver routes it through
        // `accessibilityHint` so the affordance is parity for both inputs.
        .help(tooltipLabel)
    }

    // MARK: - Medallion (circle + ring + glyph)

    private var medallion: some View {
        ZStack {
            // Base fill — accent-tinted glossy gradient for earned,
            // recessed neutral for locked / hidden.
            Circle()
                .fill(fill)
                .frame(width: medallionSize, height: medallionSize)
            // Ring — glossy gradient for earned, dotted stroke for locked.
            ring
            // Glyph — accent-tinted bold for earned, dimmed for locked.
            Image(lucide: visibleIconName)
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(
                    size: glyphSize,
                    weight: .bold
                )) // `glyphSize` is @ScaledMetric(.title2) — already Dynamic-Type-aware medallion glyph, sized to the ring, off the
                // HLIconSize scale by design.
                .foregroundStyle(glyphColor)
                .accessibilityHidden(true)
        }
        // Earned medallions get a soft accent-hued drop-shadow so they
        // read as "lit" against the canvas. Locked stay flat (the dotted
        // ring is enough visual weight).
        .shadow(
            color: achievement.unlocked && !reduceTransparency
                ? HLAccent.userBrandTint.opacity(0.18)
                : Color.clear,
            radius: 8,
            x: 0,
            y: 4
        )
    }

    @ViewBuilder
    private var ring: some View {
        if achievement.unlocked {
            // Glossy gradient ring — Apple-Fitness-Award lighting.
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
                    lineWidth: 3
                )
                .frame(width: medallionSize, height: medallionSize)
        } else {
            // Dotted stroke — outline-only "not yet filled" affordance.
            Circle()
                .strokeBorder(
                    HLColor.separator,
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                .frame(width: medallionSize, height: medallionSize)
        }
    }

    private var label: some View {
        Text(visibleTitle)
            .font(.hlCaption.weight(.medium))
            .foregroundStyle(achievement.unlocked ? HLText.primary : HLText.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Derived

    private var fill: AnyShapeStyle {
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

    private var glyphColor: Color {
        if achievement.unlocked {
            return HLAccent.userBrandTint
        }
        return HLText.tertiary
    }

    private var visibleIconName: String {
        if achievement.isHiddenPlaceholder {
            return "HelpCircle"
        }
        return achievement.iconName ?? "Trophy"
    }

    private var visibleTitle: String {
        if achievement.isHiddenPlaceholder {
            return String(localized: "Secret")
        }
        return achievement.title
    }

    /// Long-press tooltip + VoiceOver hint. Earned medallions surface
    /// a tap-for-details hint; locked ones surface "Noch nicht
    /// freigeschaltet" so the locked-state context is reachable
    /// without opening the sheet.
    private var tooltipLabel: String {
        if achievement.isHiddenPlaceholder {
            return String(localized: "Mysterious achievement — discover it")
        }
        if achievement.unlocked {
            return achievement.title
        }
        return String(localized: "Not unlocked yet")
    }
}

/// Wraps `AchievementMedallion` in a `Button` so the cell becomes tappable.
/// The selection-haptic is driven by the parent screen's `.sensoryFeedback`
/// on the selected-achievement token (avoids double-firing per cell).
struct AchievementMedallionButton: View {
    let achievement: Achievement
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AchievementMedallion(achievement: achievement)
        }
        .buttonStyle(.plain)
        .hlPressable()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityLabel: Text {
        var parts: [String] = []
        if achievement.isHiddenPlaceholder {
            parts.append(String(localized: "Secret achievement"))
        } else {
            parts.append(String(localized: "Achievement"))
            parts.append(achievement.title)
        }
        if achievement.unlocked {
            parts.append(String(localized: "earned"))
        } else if !achievement.isHiddenPlaceholder {
            parts.append(String(localized: "\(Int(round(achievement.progress * 100))) percent progress"))
        }
        if let points = achievement.points, points > 0, achievement.unlocked {
            parts.append(String(localized: "\(points) points"))
        }
        return Text(parts.joined(separator: ", "))
    }

    private var accessibilityHint: Text {
        if achievement.unlocked {
            return Text("Double-tap for details and to share.")
        }
        if achievement.isHiddenPlaceholder {
            return Text("Mysterious achievement — discover it")
        }
        return Text("Not unlocked yet. Double-tap to view progress.")
    }
}

// MARK: - Previews

#Preview("Earned — Trophy") {
    AchievementMedallion(
        achievement: Achievement(
            id: "first-login",
            key: "first-login",
            title: "Willkommen an Bord",
            description: "Erste Anmeldung",
            iconName: "Trophy",
            unlocked: true,
            unlockedAt: Date(timeIntervalSince1970: 1_716_800_000),
            progress: 1.0,
            points: 10
        )
    )
    .padding()
    .background(HLSurface.primary)
}

#Preview("Locked — partial") {
    AchievementMedallion(
        achievement: Achievement(
            id: "bp-50",
            key: "bp-50",
            title: "Vitalwerte-Profi",
            description: "50 Blutdruck-Messungen",
            iconName: "Heart",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.42,
            points: 90
        )
    )
    .padding()
    .background(HLSurface.primary)
}

#Preview("Hidden") {
    AchievementMedallion(
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
        )
    )
    .padding()
    .background(HLSurface.primary)
}

#Preview("3-col grid") {
    let achievements: [Achievement] = [
        Achievement(
            id: "1",
            key: "1",
            title: "Willkommen",
            description: "",
            iconName: "Trophy",
            unlocked: true,
            unlockedAt: Date(),
            progress: 1,
            points: 10
        ),
        Achievement(
            id: "2",
            key: "2",
            title: "Erste Messung",
            description: "",
            iconName: "Heart",
            unlocked: true,
            unlockedAt: Date(),
            progress: 1,
            points: 20
        ),
        Achievement(
            id: "3",
            key: "3",
            title: "Konsequenter Pillenfreund",
            description: "",
            iconName: "Pill",
            unlocked: true,
            unlockedAt: Date(),
            progress: 1,
            points: 60
        ),
        Achievement(
            id: "4",
            key: "4",
            title: "7-Tage-Streak",
            description: "",
            iconName: "Flame",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.7,
            points: 40
        ),
        Achievement(
            id: "5",
            key: "5",
            title: "Vitalwerte-Profi",
            description: "",
            iconName: "Activity",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.3,
            points: 90
        ),
        Achievement(
            id: "6",
            key: "6",
            title: "Spaziergänger",
            description: "",
            iconName: "Footprints",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.1,
            points: 30
        ),
        Achievement(
            id: "7",
            key: "7",
            title: "achievements.hiddenCard.title",
            description: "",
            iconName: "HelpCircle",
            unlocked: false,
            unlockedAt: nil,
            progress: 0,
            points: 25
        ),
        Achievement(
            id: "8",
            key: "8",
            title: "achievements.hiddenCard.title",
            description: "",
            iconName: "HelpCircle",
            unlocked: false,
            unlockedAt: nil,
            progress: 0,
            points: 25
        ),
        Achievement(
            id: "9",
            key: "9",
            title: "Schlafmütze",
            description: "",
            iconName: "Moon",
            unlocked: false,
            unlockedAt: nil,
            progress: 0.5,
            points: 50
        )
    ]
    let columns = [
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md)
    ]
    return ScrollView {
        LazyVGrid(columns: columns, spacing: HLSpace.lg) {
            ForEach(achievements) { a in
                AchievementMedallion(achievement: a)
            }
        }
        .padding()
    }
    .background(HLSurface.primary)
}
