import GizletUI
import SwiftUI

/// The launcher built with SwiftPM alone, for development without Xcode
/// (`scripts/dev-app.sh` wraps it in an app bundle). Releases build App/ with Xcode.
@main
struct GizletDev: App {
    var body: some Scene {
        GizletScene()
    }
}
