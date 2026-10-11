import SwiftUI

@main
struct StauklarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .tint(Theme.accent)
        }
    }
}
