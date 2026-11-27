import GizletCore
import SwiftUI

/// Cover art filling its frame: the Store's cover image, or the gizlet's own
/// color with its icon (or initial) while there is none.
struct CoverArt: View {
    var url: URL?
    var color: String?
    var name: String
    var icon: URL? = nil
    var iconFile: URL? = nil
    var iconSize: CGFloat = 72

    var body: some View {
        let base = Color(hex: color) ?? .accentColor
        Color.clear
            .overlay {
                ZStack {
                    Color.black
                    LinearGradient(colors: [base, base.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
                    if icon != nil || iconFile != nil {
                        AppIcon(file: iconFile, remote: icon, name: name, color: color, size: iconSize)
                            .rotationEffect(.degrees(-8))
                            .shadow(color: .black.opacity(0.35), radius: iconSize * 0.25, y: iconSize * 0.12)
                    } else {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: iconSize * 1.6, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    if let url {
                        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                        }
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// Lifts a card a little under the pointer.
struct Lift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.012 : 1)
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.12), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A round avatar with a profile's initials on a color of its own.
struct Avatar: View {
    @Environment(\.l) private var l
    var profile: Profile
    var size: CGFloat = 32

    var body: some View {
        let hue = Double(profile.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        let name = l.name(of: profile)
        let words = name.split(separator: " ")
        let initials = words.count > 1 ? String(words[0].prefix(1) + words[1].prefix(1)) : String(name.prefix(2))
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue, saturation: 0.7, brightness: 0.5)],
                                         startPoint: .top, endPoint: .bottom))
            Text(initials.uppercased()).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A page with a large title, scrolling, as the Store's pages are laid out.
struct PageScroll<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 34, weight: .bold)).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                }
                content()
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .largeTitlePage()
    }
}

extension View {
    /// The page draws its own large title, so the toolbar does not repeat it.
    @ViewBuilder func largeTitlePage() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// A section heading with an optional "See All" link.
struct ShelfHeader: View {
    @Environment(\.l) private var l
    var title: String
    var seeAll: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            if let seeAll { Button(l("See All", "查看全部"), action: seeAll).buttonStyle(.link) }
        }
    }
}
