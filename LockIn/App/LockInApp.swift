import SwiftUI

@main
struct LockInApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
