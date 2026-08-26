import SwiftUI

/// Top-pinned banner that surfaces offline state so the user understands
/// they're looking at cached data.
///
/// **Adoption:** `AuthenticatedShell` wraps its `TabView` body in a
/// `VStack { ReachabilityBanner(); TabView { … } }` so the banner sits
/// inside the safe area but above tab content. Each Wave-2 store consumes
/// `lastUpdatedAt` from its SWR observer to surface per-card "showing
/// cached" badges separately.
///
/// Strings live in `Localizable.xcstrings` (DE primary, EN parity).
public struct ReachabilityBanner: View {
    private let reachability: ReachabilityProviding
    @State private var isOnline: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(reachability: ReachabilityProviding) {
        self.reachability = reachability
    }

    public var body: some View {
        Group {
            if !isOnline {
                bannerContent
            }
        }
        .task {
            // Drain the stream while the banner is in the hierarchy.
            for await online in await reachability.isOnlineStream {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    isOnline = online
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bannerContent: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "wifi.slash")
                .accessibilityHidden(true)
            Text("Offline — showing cached values")
                .font(.hlCaption.weight(.semibold))
        }
        .foregroundStyle(HLText.primary)
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(HLMaterialBackground(.regularMaterial))
        .accessibilityLabel(Text("Offline. Showing cached values."))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#if DEBUG
    private final class _PreviewReach: ReachabilityProviding {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { c in
                    c.yield(online)
                    c.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    #Preview("Offline") {
        VStack {
            ReachabilityBanner(reachability: _PreviewReach(online: false))
            Spacer()
        }
        .background(HLColor.background)
    }

    #Preview("Online") {
        VStack {
            ReachabilityBanner(reachability: _PreviewReach(online: true))
            Spacer()
        }
        .background(HLColor.background)
    }
#endif
