import SwiftUI
import UIKit

@main
struct RawDropApp: App {
    init() {
        // Anything left over from a previous batch is garbage by now.
        RawExporter.purgeAllBatches()
        #if DEBUG
        HangMonitor.start()
        #endif
    }

    /// The large title is a brand moment, like the name on the intro and the
    /// widget counts, so it shares their rounded face. Small titles stay SF Pro.
    private static func styleLargeTitles() {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle)
        guard let descriptor = base.fontDescriptor
            .withDesign(.rounded)?
            .withSymbolicTraits(.traitBold) else { return }
        let font = UIFont(descriptor: descriptor, size: base.pointSize)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: font]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                // Appearance proxies must wait for UIKit; set in init they
                // reset the app's tint to system blue.
                .onAppear { Self.styleLargeTitles() }
        }
    }
}
