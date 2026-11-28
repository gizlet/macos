import Foundation

/// A gizlet as the Store lists it.
public struct StoreSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String { repo }
    public var repo: String
    public var appID: String
    public var name: String
    public var names: [String: String]?
    public var description: String?
    public var descriptions: [String: String]?
    public var kind: String?
    public var category: String?
    public var tags: [String]?
    public var color: String?
    public var iconURL: URL?
    public var coverURL: URL?
    public var version: String?
    public var tag: String?
    public var targets: [String]?
    public var tiers: [String]?
    public var downloads: Int?
    public var visibility: String?
    public var shareURL: URL?

    enum CodingKeys: String, CodingKey {
        case repo, name, names, description, descriptions, kind, category, tags, color, version, tag, targets, tiers, downloads, visibility
        case appID = "id"
        case iconURL = "icon_url"
        case coverURL = "cover_url"
        case shareURL = "share_url"
    }

    public func name(for language: String) -> String { localized(names ?? [:], language) ?? name }
    public func description(for language: String) -> String? { localized(descriptions ?? [:], language) ?? description }

    /// Whether this Mac has a package to run among the release's targets.
    public func runs(on platform: Platform) -> Bool {
        let tiers = tiers ?? ["lite"]
        return (targets ?? []).contains { target in tiers.contains { platform.runs(target: target, tier: $0) } }
    }
}

public struct StorePackage: Codable, Hashable, Sendable {
    public var file: String
    public var target: String
    public var tier: String
    public var size: UInt64?
    public var sha256: String?
    public var url: URL?
}

public struct StoreControl: Codable, Hashable, Sendable {
    public var button: String
    public var action: String
    public var actions: [String: String]?

    public func action(for language: String) -> String { localized(actions ?? [:], language) ?? action }
}

/// A gizlet's page.
public struct StoreDetail: Codable, Hashable, Sendable {
    public var summary: StoreSummary
    public var owner: String?
    public var screenshots: [URL]
    public var controls: [StoreControl]
    public var packages: [StorePackage]
    public var aboutURLs: [String: URL]
    public var githubURL: URL?
    public var license: String?

    enum CodingKeys: String, CodingKey {
        case owner, screenshots, controls, packages, license
        case aboutURLs = "about_urls"
        case githubURL = "github_url"
    }

    public init(from decoder: Decoder) throws {
        summary = try StoreSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        screenshots = try container.decodeIfPresent([URL].self, forKey: .screenshots) ?? []
        controls = try container.decodeIfPresent([StoreControl].self, forKey: .controls) ?? []
        packages = try container.decodeIfPresent([StorePackage].self, forKey: .packages) ?? []
        aboutURLs = try container.decodeIfPresent([String: URL].self, forKey: .aboutURLs) ?? [:]
        githubURL = try container.decodeIfPresent(URL.self, forKey: .githubURL)
        license = try container.decodeIfPresent(String.self, forKey: .license)
    }

    public func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
    }

    /// The package this Mac would install, in the order of its targets.
    public func package(for platform: Platform) -> StorePackage? {
        for target in platform.targets {
            if let package = packages.first(where: { $0.target == target && $0.tier == platform.tier }) ?? packages.first(where: { $0.target == target && $0.tier == "lite" }) {
                return package
            }
        }
        return nil
    }
}

public struct StoreSection: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var titles: [String: String]?
    public var gizlets: [StoreSummary]

    public func title(for language: String) -> String { localized(titles ?? [:], language) ?? title }
}

public struct StoreFeatured: Codable, Hashable, Sendable {
    public var hero: [StoreSummary]
    public var sections: [StoreSection]

    public init(hero: [StoreSummary] = [], sections: [StoreSection] = []) {
        self.hero = hero
        self.sections = sections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hero = try container.decodeIfPresent([StoreSummary].self, forKey: .hero) ?? []
        sections = try container.decodeIfPresent([StoreSection].self, forKey: .sections) ?? []
    }
}

/// What `install` answers: the package to download, with GitHub's repository id.
public struct StoreOffer: Codable, Hashable, Sendable {
    public var repo: String
    public var repositoryID: UInt64?
    public var appID: String
    public var name: String
    public var kind: String
    public var version: String
    public var tag: String
    public var package: StorePackage

    enum CodingKeys: String, CodingKey {
        case repo, name, kind, version, tag, package
        case repositoryID = "repository_id"
        case appID = "id"
    }
}

/// What `/v1/updates` says about one installed app.
public struct StoreUpdateStatus: Codable, Hashable, Sendable {
    public var repo: String
    public var repositoryID: UInt64?
    public var appID: String
    public var installed: String
    public var status: String
    public var version: String?
    public var tag: String?
    public var kind: String?
    public var package: StorePackage?

    enum CodingKeys: String, CodingKey {
        case repo, installed, status, version, tag, kind, package
        case repositoryID = "repository_id"
        case appID = "id"
    }

    public var hasUpdate: Bool { status == "update" && package != nil }
}

public struct StoreAPIError: Error, LocalizedError, Equatable {
    public var status: Int
    public var code: String
    public var message: String

    public var errorDescription: String? { message }
    public static let offline = StoreAPIError(status: 0, code: "offline", message: "The Gizlet Store cannot be reached; check the connection")
}

/// The Gizlet Store's public API at `gizlet.io/api/v1`.
public struct StoreClient: Sendable {
    public static let defaultAPI = URL(string: "https://gizlet.io/api")!
    public var api: URL
    public var platform: Platform
    var session: URLSession

    public init(api: URL = StoreClient.defaultAPI, platform: Platform = .current, session: URLSession = .shared) {
        self.api = api
        self.platform = platform
        self.session = session
    }

    /// `GIZLET_STORE_API` points the launcher at another Store.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> StoreClient {
        if let value = environment["GIZLET_STORE_API"], let url = URL(string: value), url.scheme == "https" || url.host == "localhost" {
            return StoreClient(api: url)
        }
        return StoreClient()
    }

    /// The whole catalog of apps and games, not only what this Mac runs: the
    /// launcher marks each with whether it has a Mac package, so gizlets made
    /// for handhelds still show (and show up the moment a Mac package lands).
    private var catalogQuery: [URLQueryItem] {
        [URLQueryItem(name: "kind", value: "app")]
    }

    public func featured() async throws -> StoreFeatured {
        try await get("/v1/featured", catalogQuery)
    }

    /// Listed gizlets, optionally of one category (`game` or `app`) and matching words.
    public func browse(category: String? = nil, words: String? = nil, sort: String = "score") async throws -> [StoreSummary] {
        struct Page: Decodable { var gizlets: [StoreSummary] }
        var query = catalogQuery + [URLQueryItem(name: "sort", value: sort), URLQueryItem(name: "limit", value: "48")]
        if let category { query.append(URLQueryItem(name: "category", value: category)) }
        if let words = words?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            query.append(URLQueryItem(name: "q", value: words))
        }
        let page: Page = try await get("/v1/gizlets", query)
        return page.gizlets
    }

    public func search(_ words: String) async throws -> [StoreSummary] {
        try await browse(words: words)
    }

    public func detail(_ repo: String) async throws -> StoreDetail {
        try await get("/v1/gizlets/\(try repoPath(repo))", [])
    }

    /// The package to install, asking for each target this Mac runs in turn.
    public func offer(_ repo: String) async throws -> StoreOffer {
        var lastError: Error = StoreAPIError(status: 404, code: "no_compatible_package", message: "No package for this Mac")
        for target in platform.targets {
            do {
                return try await get("/v1/gizlets/\(try repoPath(repo))/install", [
                    URLQueryItem(name: "target", value: target), URLQueryItem(name: "tier", value: platform.tier),
                ])
            } catch let error as StoreAPIError where error.code == "no_compatible_package" {
                lastError = error
            }
        }
        throw lastError
    }

    public struct InstalledItem: Encodable, Sendable {
        public var repo: String
        public var repositoryID: UInt64?
        public var id: String
        public var version: String

        public init(repo: String, repositoryID: UInt64?, id: String, version: String) {
            self.repo = repo
            self.repositoryID = repositoryID
            self.id = id
            self.version = version
        }

        enum CodingKeys: String, CodingKey {
            case repo, id, version
            case repositoryID = "repository_id"
        }
    }

    public func updates(_ installed: [InstalledItem]) async throws -> [StoreUpdateStatus] {
        struct Body: Encodable { var target: String; var tier: String; var installed: [InstalledItem] }
        struct Answer: Decodable { var gizlets: [StoreUpdateStatus] }
        guard !installed.isEmpty else { return [] }
        var statuses: [StoreUpdateStatus] = []
        var ask = installed
        // This Mac's own target first; an app with no package for it is asked
        // again for the next target it runs. The API takes 200 apps a request.
        for target in platform.targets where !ask.isEmpty {
            var answered: [StoreUpdateStatus] = []
            for start in stride(from: 0, to: ask.count, by: 200) {
                var request = URLRequest(url: api.appendingPathComponent("/v1/updates"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(Body(target: target, tier: platform.tier, installed: Array(ask[start..<min(start + 200, ask.count)])))
                let answer: Answer = try await send(request)
                answered += answer.gizlets
            }
            statuses.removeAll { status in answered.contains { $0.appID == status.appID } }
            statuses += answered
            ask.removeAll { item in !answered.contains { $0.status == "no_package" && $0.appID == item.id } }
        }
        return statuses
    }

    private func repoPath(_ repo: String) throws -> String {
        let parts = repo.split(separator: "/")
        guard parts.count == 3, parts[0] == "github.com",
              parts[1...].allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && $0 != "." && $0 != ".." })
        else { throw StoreAPIError(status: 400, code: "bad_repo", message: "\(repo) is not a GitHub repository") }
        return parts.joined(separator: "/")
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return try await send(URLRequest(url: components.url!))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .timedOut, .dnsLookupFailed].contains(error.code) {
            throw StoreAPIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let failure = try? JSONDecoder().decode(APIFailure.self, from: data) {
                throw StoreAPIError(status: status, code: failure.error.code, message: failure.error.message)
            }
            throw StoreAPIError(status: status, code: "http_\(status)", message: "The Gizlet Store answered \(status)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StoreAPIError(status: status, code: "bad_answer", message: "The Gizlet Store sent an answer this version cannot read")
        }
    }
}

private struct APIFailure: Decodable {
    struct Body: Decodable {
        var code: String
        var message: String
    }

    var error: Body
}
