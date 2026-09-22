import SwiftUI

@main
struct AIUsageWidgetApp: App {
    @StateObject private var manager = UsageManager.shared
    
    var body: some Scene {
        MenuBarExtra {
            MainPopoverView()
        } label: {
            Image(nsImage: manager.menuBarImage)
                .help("Tokens: today on this Mac, excluding cache reads. + means partial history; — means unavailable. Claude percentage: account-wide weekly usage.")
        }
        .menuBarExtraStyle(.window)
    }
}
