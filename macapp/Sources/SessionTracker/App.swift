import AppKit
import SwiftUI

@main
struct SessionTrackerApp: App {
    @StateObject private var store = SessionStore()
    private let chatgptMonitor = ChatGPTMonitor()
    private let chatgptBrowserHistoryMonitor = ChatGPTBrowserHistoryMonitor()
    private let chatgptSidebarMonitor = ChatGPTSidebarMonitor()

    init() {
        chatgptMonitor.start()
        chatgptBrowserHistoryMonitor.start()
        chatgptSidebarMonitor.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}
