import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .shows
    @State private var showsResetRequest = 0
    @State private var settingsAllowsTabSwipe = true

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: select
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            DiscoverView()
                .tag(AppTab.discover)
                .tabItem { Label("Discover", systemImage: "sparkles.tv.fill") }

            ShowsView(
                scrollToTodayRequest: showsResetRequest,
                onDiscover: { select(.discover) }
            )
                .tag(AppTab.shows)
                .tabItem { Label("Shows", systemImage: "play.tv.fill") }

            ProfileView(allowsTabSwipe: $settingsAllowsTabSwipe)
                .tag(AppTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(AppTheme.accent)
        .simultaneousGesture(tabSwipeGesture)
        .onAppear {
            showsResetRequest &+= 1
        }
    }

    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard (selection != .settings || settingsAllowsTabSwipe),
                      abs(horizontal) >= 100,
                      abs(horizontal) > abs(vertical) * 1.5,
                      let destination = tab(inSwipeDirection: horizontal) else {
                    return
                }
                withAnimation(.snappy) {
                    select(destination)
                }
            }
    }

    private func tab(inSwipeDirection horizontal: CGFloat) -> AppTab? {
        if horizontal < 0 {
            switch selection {
            case .discover: return nil
            case .shows: return .discover
            case .settings: return .shows
            }
        }

        switch selection {
        case .discover: return .shows
        case .shows: return .settings
        case .settings: return nil
        }
    }

    private func select(_ newSelection: AppTab) {
        selection = newSelection
        guard newSelection == .shows else { return }

        DispatchQueue.main.async {
            showsResetRequest &+= 1
        }
    }
}
