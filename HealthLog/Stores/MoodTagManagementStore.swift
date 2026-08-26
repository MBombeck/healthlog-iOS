import Foundation
import Observation

/// Authoritative state for mood-tag groups, layout, visibility, archive, and
/// purge. This is deliberately separate from the fail-soft capture catalog:
/// management loads `include=hidden,archived,usage` plus the layout endpoint
/// and surfaces every read or mutation error.
///
/// Each mutation is followed by a fresh catalog and layout read. That includes
/// partial custom-tag moves where the relational PATCH succeeds but the layout
/// PUT fails, so local state always converges back to the server.
@MainActor
@Observable
public final class MoodTagManagementStore {
    public private(set) var catalog: MoodTagCatalog = .init(categories: [])
    public private(set) var layout: MoodTagLayoutDTO = .init(groupOrder: [], placements: [:])
    public private(set) var didLoad = false
    public private(set) var isLoading = false
    public private(set) var loadError: HLError?
    public private(set) var mutationError: HLError?
    public private(set) var isMutating = false

    private let repo: MoodTagCatalogRepository

    public init(repo: MoodTagCatalogRepository) {
        self.repo = repo
    }

    public func load() async {
        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }
        do {
            let nextCatalog = try await repo.managementCatalog()
            let nextLayout = try await repo.layout()
            catalog = nextCatalog
            layout = nextLayout
            loadError = nil
        } catch let error as HLError {
            loadError = error
        } catch {
            loadError = .unknown(error.localizedDescription)
        }
    }

    /// Every resolved group in display order. The management GET already
    /// applies the layout and keeps empty user-owned groups.
    public var groups: [MoodTagCategoryDTO] {
        catalog.categories
    }

    /// Active custom tags across the resolved tree. A moved custom tag may live
    /// under any seeded or user-owned group, not only the seeded `custom` node.
    public var customTags: [MoodTagDTO] {
        catalog.categories
            .flatMap(\.tags)
            .filter { $0.custom && !$0.archived }
    }

    public var archivedCustomTags: [MoodTagDTO] {
        catalog.categories
            .flatMap(\.tags)
            .filter { $0.custom && $0.archived }
    }

    /// Complete placement map for the visible tree. Archived tags are excluded
    /// because they do not participate in capture ordering; hidden catalogue
    /// tags remain so un-hiding does not lose their chosen position.
    public var visiblePlacements: [String: [String]] {
        Dictionary(
            uniqueKeysWithValues: catalog.categories.map { category in
                (category.key, category.tags.filter { !$0.archived }.map(\.key))
            }
        )
    }

    @discardableResult
    public func createCustom(label: String, icon: String?, categoryKey: String?) async -> Bool {
        await mutate {
            try await self.repo.createCustom(label: label, icon: icon, categoryKey: categoryKey)
        }
    }

    @discardableResult
    public func updateCustom(
        key: String,
        label: String?,
        icon: String?,
        categoryKey: String?
    ) async -> Bool {
        await mutate {
            try await self.repo.updateCustom(
                key: key,
                label: label,
                icon: icon,
                isActive: nil,
                categoryKey: categoryKey
            )
        }
    }

    @discardableResult
    public func setCustomActive(key: String, isActive: Bool) async -> Bool {
        await mutate {
            try await self.repo.updateCustom(
                key: key,
                label: nil,
                icon: nil,
                isActive: isActive
            )
        }
    }

    @discardableResult
    public func deleteCustom(key: String, purge: Bool) async -> Bool {
        await mutate {
            try await self.repo.deleteCustom(key: key, purge: purge)
        }
    }

    @discardableResult
    public func setCatalogueHidden(key: String, hidden: Bool) async -> Bool {
        await mutate {
            try await self.repo.setCatalogueHidden(key: key, hidden: hidden)
        }
    }

    @discardableResult
    public func createGroup(label: String, icon: String?) async -> Bool {
        await mutate {
            try await self.repo.createGroup(label: label, icon: icon)
        }
    }

    @discardableResult
    public func updateGroup(key: String, label: String?, icon: String?) async -> Bool {
        await mutate {
            try await self.repo.updateGroup(key: key, label: label, icon: icon, isActive: nil)
        }
    }

    @discardableResult
    public func deleteGroup(key: String, purge: Bool = false) async -> Bool {
        await mutate {
            try await self.repo.deleteGroup(key: key, purge: purge)
        }
    }

    @discardableResult
    public func moveGroup(key: String, by delta: Int) async -> Bool {
        var order = catalog.categories.map(\.key)
        guard let index = order.firstIndex(of: key) else { return false }
        let destination = index + delta
        guard order.indices.contains(destination) else { return false }
        order.swapAt(index, destination)
        let updatedOrder = order
        return await mutate {
            try await self.repo.updateGroupOrder(updatedOrder)
        }
    }

    @discardableResult
    public func moveTagWithinGroup(key: String, groupKey: String, by delta: Int) async -> Bool {
        guard let group = catalog.categories.first(where: { $0.key == groupKey }) else {
            return false
        }
        var keys = group.tags.filter { !$0.archived }.map(\.key)
        guard let index = keys.firstIndex(of: key) else { return false }
        let destination = index + delta
        guard keys.indices.contains(destination) else { return false }
        keys.swapAt(index, destination)
        var placements = visiblePlacements
        placements[groupKey] = keys
        let updatedPlacements = placements
        return await mutate {
            try await self.repo.updatePlacements(updatedPlacements)
        }
    }

    /// Custom moves first change the relational home group, then persist the
    /// complete visible placement map. Any failure triggers a management reload,
    /// including a layout failure after a successful custom PATCH.
    @discardableResult
    public func moveTag(key: String, to targetGroupKey: String) async -> Bool {
        guard let tag = catalog.categories.lazy.flatMap(\.tags).first(where: { $0.key == key }) else {
            return false
        }
        var placements = visiblePlacements
        for groupKey in Array(placements.keys) {
            placements[groupKey]?.removeAll { $0 == key }
        }
        guard placements[targetGroupKey] != nil else { return false }
        placements[targetGroupKey]?.append(key)
        let updatedPlacements = placements

        return await mutate {
            if tag.custom {
                _ = try await self.repo.updateCustom(
                    key: key,
                    label: nil,
                    icon: nil,
                    isActive: nil,
                    categoryKey: targetGroupKey
                )
            }
            _ = try await self.repo.updatePlacements(updatedPlacements)
        }
    }

    public func clearMutationError() {
        mutationError = nil
    }

    public func clearOnLogout() {
        catalog = .init(categories: [])
        layout = .init(groupOrder: [], placements: [:])
        didLoad = false
        isLoading = false
        loadError = nil
        mutationError = nil
        isMutating = false
    }

    /// Runs a mutation and always reloads the authoritative catalog and layout,
    /// regardless of whether the write fully or partially succeeded.
    private func mutate(_ work: @Sendable () async throws -> Void) async -> Bool {
        isMutating = true
        mutationError = nil
        var writeError: HLError?
        do {
            try await work()
        } catch let error as HLError {
            writeError = error
        } catch {
            writeError = .unknown(error.localizedDescription)
        }

        await load()
        isMutating = false

        if let writeError {
            mutationError = writeError
            return false
        }
        if let loadError {
            mutationError = loadError
            return false
        }
        return true
    }

    private func mutate(_ work: @Sendable () async throws -> some Any) async -> Bool {
        await mutate { _ = try await work() }
    }
}
