import GizletCore
import SwiftUI

extension StoreSummary {
    var isGame: Bool { category == "game" }

    func kindLabel(_ l: Localizer) -> String {
        isGame ? l("Game", "游戏") : l("App", "应用")
    }
}

// MARK: Pages

/// Loading and error states shared by the Store's pages.
struct StoreLoading<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    var ready: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        let store = model.storeModel!
        Group {
            if ready {
                content()
            } else if let error = store.error {
                EmptyState(symbol: "wifi.exclamationmark", title: l("The Store cannot be reached", "无法连接商店"), message: error) {
                    Button(l("Try Again", "重试")) { Task { await store.reload() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await store.load() }
        .toolbar {
            ToolbarItem {
                Button { Task { await store.reload() } } label: { Label(l("Reload", "刷新"), systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help(l("Reload the Store", "刷新商店"))
            }
        }
    }
}

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        let store = model.storeModel!
        StoreLoading(ready: store.featured != nil) {
            PageScroll(title: l("Discover", "发现")) {
                if let featured = store.featured {
                    if !featured.hero.isEmpty { HeroCarousel(items: featured.hero) }
                    let picks = featured.sections.first?.gizlets.filter { item in !featured.hero.prefix(1).contains(item) } ?? []
                    if picks.count >= 2, let section = featured.sections.first {
                        HStack(spacing: 20) {
                            ForEach(picks.prefix(2)) { EditorialCard(item: $0, eyebrow: section.title(for: l.tag)) }
                        }
                    }
                    ForEach(featured.sections) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            ShelfHeader(title: section.title(for: l.tag), seeAll: seeAll(section))
                            if section.id == "games" || section.id == "apps" {
                                ListGrid(items: section.gizlets)
                            } else {
                                Shelf(items: section.gizlets)
                            }
                        }
                    }
                    FlashPromo()
                }
            }
        }
    }

    private func seeAll(_ section: StoreSection) -> (() -> Void)? {
        switch section.id {
        case "games": { model.section = .games }
        case "apps": { model.section = .apps }
        default: nil
        }
    }
}

/// The Games or Apps page: the top entry as a hero, then all of them.
struct ShelfPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    var shelf: StoreModel.Shelf

    var body: some View {
        let store = model.storeModel!
        let items = store.shelves[shelf]
        StoreLoading(ready: items != nil) {
            PageScroll(title: shelf == .games ? l("Games", "游戏") : l("Apps", "应用")) {
                let items = items ?? []
                if items.isEmpty {
                    EmptyState(symbol: shelf == .games ? "gamecontroller" : "square.grid.2x2", title: l("Nothing here yet", "这里还没有内容"),
                               message: l("New gizlets appear here once they are published and approved.", "新的作品发布并通过审核后会出现在这里。"))
                } else {
                    if let top = items.first(where: { $0.coverURL != nil }) ?? items.first {
                        HeroCard(item: top, eyebrow: shelf == .games ? l("Top game", "热门游戏") : l("Top app", "热门应用"))
                    }
                    ShelfHeader(title: shelf == .games ? l("All Games", "全部游戏") : l("All Apps", "全部应用"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 22)], alignment: .leading, spacing: 26) {
                        ForEach(items) { GameCard(item: $0) }
                    }
                }
            }
        }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        let store = model.storeModel!
        PageScroll(title: l("Results for “\(store.query.trimmingCharacters(in: .whitespaces))”", "“\(store.query.trimmingCharacters(in: .whitespaces))”的搜索结果")) {
            if let results = store.results {
                if results.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: l("Nothing found", "没有找到"),
                               message: l("Try other words, or a gizlet's short link.", "换个关键词试试。"))
                } else {
                    ListGrid(items: results)
                }
            } else if let error = store.searchError {
                EmptyState(symbol: "wifi.exclamationmark", title: l("Search failed", "搜索失败"), message: error) {
                    Button(l("Try Again", "重试")) { store.retrySearch() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Cards

/// Featured gizlets in turn, a new one every few seconds.
struct HeroCarousel: View {
    @Environment(\.l) private var l
    let items: [StoreSummary]
    @State private var index = 0
    @State private var hovering = false

    var body: some View {
        let current = items[min(index, items.count - 1)]
        ZStack(alignment: .bottom) {
            HeroCard(item: current, eyebrow: current.isGame ? l("Featured game", "精选游戏") : l("Featured app", "精选应用"))
                .id(current.repo)
                .transition(.opacity)
            if items.count > 1 {
                HStack(spacing: 7) {
                    ForEach(items.indices, id: \.self) { i in
                        Button { withAnimation(.easeInOut(duration: 0.4)) { index = i } } label: {
                            Capsule().fill(.white.opacity(i == index ? 0.95 : 0.4)).frame(width: i == index ? 20 : 7, height: 7)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(items[i].name(for: l.tag))
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .onHover { hovering = $0 }
        .task(id: items.count) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if !hovering, items.count > 1 { withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count } }
            }
        }
    }
}

/// A wide banner: the cover with the name, description and action over it.
struct HeroCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let item: StoreSummary
    var eyebrow: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverArt(url: item.coverURL, color: item.color, name: item.name, icon: item.coverURL == nil ? item.iconURL : nil, iconSize: 150)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [(Color(hex: item.color) ?? .black).opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow.uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(.white.opacity(0.75))
                    Text(item.name(for: l.tag)).font(.system(size: 38, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    if let description = item.description(for: l.tag) {
                        Text(description).font(.title3).foregroundStyle(.white.opacity(0.85)).lineLimit(2).frame(maxWidth: 560, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    AppIcon(remote: item.iconURL, name: item.name, color: item.color, size: 58)
                    StoreActionButton(item: item, large: true)
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 38)
        }
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .modifier(Lift())
        .opensDetail(item)
    }
}

/// A large card with words on the left and round art on the right.
struct EditorialCard: View {
    @Environment(\.l) private var l
    let item: StoreSummary
    var eyebrow: String

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow.uppercased()).font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                Text(item.name(for: l.tag)).font(.system(size: 28, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.75)
                Text(item.description(for: l.tag) ?? "").font(.body).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 8)
                StoreActionButton(item: item)
            }
            .frame(minWidth: 180, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
            CoverArt(url: item.coverURL, color: item.color, name: item.name, icon: item.iconURL, iconSize: 84)
                .frame(minWidth: 96, maxWidth: 190, minHeight: 96, maxHeight: 190)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(Circle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.4)))
        .modifier(Lift())
        .opensDetail(item)
    }
}

/// Cover art with the icon, name and action below it.
struct GameCard: View {
    @Environment(\.l) private var l
    let item: StoreSummary
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CoverArt(url: item.coverURL, color: item.color, name: item.name, icon: item.coverURL == nil ? item.iconURL : nil)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .modifier(Lift())
            HStack(spacing: 11) {
                AppIcon(remote: item.iconURL, name: item.name, color: item.color, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name(for: l.tag)).font(.headline).lineLimit(1)
                    Text(item.description(for: l.tag) ?? item.kindLabel(l)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                StoreActionButton(item: item)
            }
        }
        .frame(width: width)
        .opensDetail(item)
    }
}

/// A row of cards scrolling sideways.
struct Shelf: View {
    let items: [StoreSummary]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 22) {
                ForEach(items) { GameCard(item: $0, width: 300) }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 2)
        }
        .padding(.vertical, -10)
    }
}

/// Icon rows in columns, as the Store lists categories and results.
struct ListGrid: View {
    @Environment(\.l) private var l
    let items: [StoreSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 24)], alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        AppIcon(remote: item.iconURL, name: item.name, color: item.color, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name(for: l.tag)).font(.headline).lineLimit(1)
                            Text(item.description(for: l.tag) ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.kindLabel(l)).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        StoreActionButton(item: item)
                    }
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 78)
                }
                .opensDetail(item)
            }
        }
    }
}

/// Asks to write a card, for the gizlets that run on handhelds.
struct FlashPromo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 52)).foregroundStyle(.white)
                .frame(width: 110, height: 110)
                .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(l("PLAY ON A HANDHELD", "在掌机上玩")).font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                Text(l("Turn an R36S into a Gizlet handheld", "把 R36S 变成 Gizlet 掌机")).font(.title2.bold())
                Text(l("Gizlets marked Handheld run on Gizlet OS. Write it to the R36S's TF card from here.", "标有“掌机”的作品运行在 Gizlet OS 上。在这里就能把它写入 R36S 的 TF 卡。"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l("Flash a Card", "刷写卡片")) { model.section = .flash }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        }
        .padding(26)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.4)))
    }
}

extension View {
    /// Clicking the card opens the gizlet's page; its own buttons still work.
    func opensDetail(_ item: StoreSummary) -> some View {
        modifier(OpensDetail(item: item))
    }
}

private struct OpensDetail: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let item: StoreSummary

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { model.storeModel.path.append(item) }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: l("Show details", "查看详情")) { model.storeModel.path.append(item) }
    }
}

// MARK: Actions

/// Get, Update, Play or Handheld, by what is installed and what this Mac runs.
struct StoreActionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let item: StoreSummary
    var large = false

    var body: some View {
        let store = model.storeModel!
        Group {
            if let progress = store.installing[item.repo] {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(large ? .regular : .small).frame(width: 64)
            } else if let installed = store.installed(item) {
                if model.appUpdates[installed.id] != nil {
                    capsule(l("Update", "更新")) { Task { await model.upgrade(installed.id) } }
                } else {
                    capsule(item.isGame ? l("Play", "开始") : l("Open", "打开")) { model.launch(installed) }
                }
            } else if model.apps.contains(where: { $0.id == item.appID }) {
                Text(l("Installed", "已安装")).font(.callout).foregroundStyle(.secondary)
            } else if item.runs(on: model.platform) {
                capsule(l("Get", "获取")) { Task { await store.install(item) } }
            } else {
                HandheldBadge(large: large)
            }
        }
        .fixedSize()
    }

    private func capsule(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).fontWeight(.semibold).frame(minWidth: large ? 76 : 44) }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(large ? .large : .regular)
    }
}

/// A gizlet that has no Mac package: it runs on Gizlet OS handhelds.
struct HandheldBadge: View {
    @Environment(\.l) private var l
    var large = false

    var body: some View {
        Label(l("Handheld", "掌机"), systemImage: "gamecontroller")
            .font(large ? .callout.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 8 : 5)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
            .help(l("Runs on Gizlet OS handhelds; there is no Mac version yet.", "运行在 Gizlet OS 掌机上，暂无 Mac 版。"))
    }
}

// MARK: Gizlet page

struct StoreDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let summary: StoreSummary

    var body: some View {
        let detail = model.storeModel.details[summary.repo]
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ZStack(alignment: .bottomLeading) {
                    CoverArt(url: summary.coverURL, color: summary.color, name: summary.name, icon: summary.coverURL == nil ? summary.iconURL : nil, iconSize: 140)
                    LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.82), location: 1)], startPoint: .top, endPoint: .bottom)
                    HStack(alignment: .bottom, spacing: 18) {
                        AppIcon(remote: summary.iconURL, name: summary.name, color: summary.color, size: 104)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.kindLabel(l).uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(.white.opacity(0.75))
                            Text(summary.name(for: l.tag)).font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                            if let owner = detail?.owner { Text(owner).font(.title3).foregroundStyle(.white.opacity(0.8)) }
                        }
                        Spacer()
                        StoreActionButton(item: summary, large: true)
                    }
                    .padding(30)
                }
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .environment(\.colorScheme, .dark)

                facts(detail)

                if let description = summary.description(for: l.tag) {
                    Text(description).font(.title3).textSelection(.enabled).frame(maxWidth: 760, alignment: .leading)
                }

                if let detail {
                    if !detail.screenshots.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: l("Screenshots", "截图"))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(detail.screenshots, id: \.self) { url in
                                        CoverArt(url: url, color: summary.color, name: summary.name)
                                            .frame(width: 340, height: 255)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                    if !detail.controls.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ShelfHeader(title: l("Controls", "操作"))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 10) {
                                ForEach(detail.controls, id: \.self) { control in
                                    HStack(spacing: 10) {
                                        Text(control.button.uppercased()).font(.caption.monospaced().bold())
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                        Text(control.action(for: l.tag))
                                    }
                                }
                            }
                        }
                    }
                    if detail.package(for: model.platform) == nil {
                        Label(l("No Mac version yet. It runs on Gizlet OS handhelds; write Gizlet OS to an R36S card in Flash.",
                                "暂无 Mac 版。它运行在 Gizlet OS 掌机上，可以在“刷机”中把 Gizlet OS 写入 R36S 的卡。"), systemImage: "gamecontroller")
                            .foregroundStyle(.secondary)
                    }
                    if let share = summary.shareURL {
                        Link(l("View on gizlet.io", "在 gizlet.io 上查看"), destination: share)
                    }
                } else if let error = model.storeModel.detailErrors[summary.repo] {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                        Button(l("Try Again", "重试")) { Task { await model.storeModel.detail(summary.repo) } }
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(summary.name(for: l.tag))
        .task { await model.storeModel.detail(summary.repo) }
    }

    /// Category, version, license and where it runs, as a row of facts.
    private func facts(_ detail: StoreDetail?) -> some View {
        let runsHere = summary.runs(on: model.platform)
        let items: [(String, String)] = [
            (l("Category", "类别"), summary.kindLabel(l)),
            (l("Version", "版本"), summary.version ?? "—"),
            (l("Runs on", "运行于"), runsHere ? l("This Mac", "这台 Mac") : l("Handhelds", "掌机")),
            (l("License", "许可"), detail?.license ?? "—"),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Divider().frame(height: 36) }
                VStack(spacing: 4) {
                    Text(fact.0.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(fact.1).font(.title3.weight(.semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
