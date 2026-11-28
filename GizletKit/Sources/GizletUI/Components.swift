import GizletCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.gzl` packages are zips.
    static let gizletPackage = UTType(filenameExtension: "gzl", conformingTo: .zip) ?? .zip
}

extension Color {
    /// `#RRGGBB`.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// A rounded icon: an image file, a remote image, or the name's initial on the app's color.
struct AppIcon: View {
    var file: URL?
    var remote: URL?
    var name: String
    var color: String?
    var size: CGFloat = 64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Group {
            if let file, let image = NSImage(contentsOf: file) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let remote {
                AsyncImage(url: remote) { phase in
                    if let image = phase.image { image.resizable().interpolation(.high) } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: size * 0.05, y: size * 0.03)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: color) ?? .accentColor, (Color(hex: color) ?? .accentColor).opacity(0.7)], startPoint: .top, endPoint: .bottom)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// A large empty-state message with an optional action.
struct EmptyState<Action: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            action().padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
