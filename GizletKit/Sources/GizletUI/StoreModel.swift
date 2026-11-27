import GizletCore
import Observation
import SwiftUI

/// The Store's pages: Discover (the featured hero and sections), the Games and
/// Apps shelves, search from the sidebar, gizlet pages and installs.
@MainActor @Observable
public final class StoreModel {
    public enum Shelf: String { case games = "game", apps = "app" }

    unowned let app: AppModel
    let client: StoreClient

    public private(set) var featured: StoreFeatured?
    public private(set) var shelves: [Shelf: [StoreSummary]] = [:]
    public private(set) var results: [StoreSummary]?
    public private(set) var loading = false
    public private(set) var error: String?
    /// The sidebar's search text; non-empty shows the results page.
    public var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// Gizlet pages opened from any Store page.
    public var path: [StoreSummary] = []
    public private(set) var details: [String: StoreDetail] = [:]
    /// Why the last search or a gizlet's page could not load.
    public private(set) var searchError: String?
    public private(set) var detailErrors: [String: String] = [:]
    public private(set) var installing: [String: Double] = [:]
    private var searchTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        client = .standard()
    }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var loadTask: Task<Void, Never>?

    /// Loads the Store once; pages call it as they appear.
    public func load() async {
        guard featured == nil else { return }
        await reload()
    }

    /// Loads the pages afresh. The load belongs to the model, not to the view
    /// that asked, so a page redrawn meanwhile does not cancel it.
    public func reload() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [client] in
            loading = true
            defer { loading = false }
            do {
                async let featured = client.featured()
                async let games = client.browse(category: Shelf.games.rawValue)
                async let apps = client.browse(category: Shelf.apps.rawValue)
                let loaded = try await (featured, games, apps)
                self.featured = loaded.0
                shelves[.games] = loaded.1
                shelves[.apps] = loaded.2
                error = nil
            } catch {
                self.error = app.l.describe(error)
            }
            await app.checkAppUpdates()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    public func retrySearch() {
        queryChanged()
    }

    private func queryChanged() {
        searchTask?.cancel()
        searchError = nil
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            results = nil
            return
        }
        path = []
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.search(words)
                guard !Task.isCancelled else { return }
                results = found
                searchError = nil
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { searchError = app.l.describe(error) }
            }
        }
    }

    public func detail(_ repo: String) async {
        do {
            detailErrors[repo] = nil
            details[repo] = try await client.detail(repo)
        } catch is CancellationError {
        } catch {
            detailErrors[repo] = app.l.describe(error)
        }
    }

    /// The installed app a Store entry is, matched by its ID and the repository it came from.
    public func installed(_ summary: StoreSummary) -> InstalledApp? {
        guard let installed = app.apps.first(where: { $0.id == summary.appID }) else { return nil }
        let origin = app.origin(of: summary.appID)
        return origin == nil || origin?.repo == summary.repo ? installed : nil
    }

    /// Cover art an installed app's Store entry has, for the Library's tiles.
    public func cover(for appID: String) -> URL? {
        let all = (featured?.hero ?? []) + (featured?.sections.flatMap(\.gizlets) ?? []) + shelves.values.flatMap { $0 }
        return all.first { $0.appID == appID }?.coverURL
    }

    public func install(_ summary: StoreSummary) async {
        guard installing[summary.repo] == nil else { return }
        installing[summary.repo] = 0
        defer { installing.removeValue(forKey: summary.repo) }
        let repo = summary.repo
        do {
            _ = try await app.storeInstall(repo, appID: summary.appID) { done, total in
                Task { @MainActor [weak self] in
                    if let total, total > 0, self?.installing[repo] != nil { self?.installing[repo] = Double(done) / Double(total) }
                }
            }
        } catch {
            app.report(error, app.l("Cannot install \(summary.name(for: app.l.tag))", "无法安装\(summary.name(for: app.l.tag))"))
        }
    }
}
