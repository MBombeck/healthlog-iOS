@testable import HealthLog
import SwiftUI
import Testing

/// The four states of loaded content. The container shows exactly one of
/// them, and it builds only that one: loaded content must never be built
/// over data that is not there yet.
@MainActor
@Suite("State container")
struct HLStateContainerTests {
    private final class Builds {
        var skeleton = 0
        var empty = 0
        var content = 0

        func view(_ count: ReferenceWritableKeyPath<Builds, Int>) -> some View {
            self[keyPath: count] += 1
            return Color.clear
        }
    }

    private func builds(for phase: HLLoadPhase, placement: HLStatePlacement) -> Builds {
        let builds = Builds()
        let container = HLStateContainer(phase, placement: placement) {
            builds.view(\.skeleton)
        } empty: {
            builds.view(\.empty)
        } content: {
            builds.view(\.content)
        }
        _ = container.body
        return builds
    }

    @Test("phases compare by their case; the retry closure is not part of it")
    func phaseEquality() {
        #expect(HLLoadPhase.loading == .loading)
        #expect(HLLoadPhase.error(retry: {}) == .error(retry: {}))
        #expect(HLLoadPhase.empty != .loaded)
        #expect(HLLoadPhase.loading != .error(retry: {}))
    }

    @Test("the empty and the failed state stand in the upper three quarters of the visible height")
    func freeArea() {
        #expect(HLStateLayout.freeAreaShare == 0.75)
    }

    @Test("while loading only the skeleton is built", arguments: [HLStatePlacement.page, .rows])
    func loadingBuildsSkeleton(placement: HLStatePlacement) {
        let builds = builds(for: .loading, placement: placement)
        #expect(builds.skeleton == 1)
        #expect(builds.empty == 0)
        #expect(builds.content == 0)
    }

    @Test("loaded content is built only when there is content", arguments: [HLStatePlacement.page, .rows])
    func loadedBuildsContent(placement: HLStatePlacement) {
        let builds = builds(for: .loaded, placement: placement)
        #expect(builds.content == 1)
        #expect(builds.skeleton == 0)
        #expect(builds.empty == 0)
    }

    @Test("an empty or failed load builds neither skeleton nor content", arguments: [HLStatePlacement.page, .rows])
    func emptyAndErrorBuildNoContent(placement: HLStatePlacement) {
        for phase in [HLLoadPhase.empty, .error(retry: {})] {
            let builds = builds(for: phase, placement: placement)
            #expect(builds.skeleton == 0)
            #expect(builds.content == 0)
        }
    }

    @Test("as list rows the caller's empty rows pass through")
    func emptyRowsPassThrough() {
        #expect(builds(for: .empty, placement: .rows).empty == 1)
        #expect(builds(for: .error(retry: {}), placement: .rows).empty == 0)
    }
}
