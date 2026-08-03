import SwiftUI

@main
struct TVTimeApp: App {
    @StateObject private var store = ShowStore()
    @AppStorage("darkModeEnabled") private var darkModeEnabled = true

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environment(\.timeZone, store.timeZone)
                .preferredColorScheme(darkModeEnabled ? .dark : .light)
        }
    }
}
