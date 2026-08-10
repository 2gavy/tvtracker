import SwiftUI

struct RootView: View {
    @State private var selection: AppTab = .shows
    @State private var showsResetRequest = 0
    @State private var settingsAllowsTabSwipe = true
    @State private var discoverCarouselIsInteracting = false
    @State private var tabContentOffset: CGFloat = 0
    @State private var tabContentOpacity = 1.0
    @State private var isTransitioningTabs = false

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: select
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            DiscoverView(
                isActive: selection == .discover,
                carouselIsInteracting: $discoverCarouselIsInteracting
            )
                .offset(x: tabContentOffset)
                .opacity(tabContentOpacity)
                .tag(AppTab.discover)
                .tabItem { Label("Discover", systemImage: "sparkles.tv.fill") }

            ShowsView(
                scrollToTodayRequest: showsResetRequest,
                onDiscover: { select(.discover) }
            )
                .offset(x: tabContentOffset)
                .opacity(tabContentOpacity)
                .tag(AppTab.shows)
                .tabItem { Label("Shows", systemImage: "play.tv.fill") }

            ProfileView(allowsTabSwipe: $settingsAllowsTabSwipe)
                .offset(x: tabContentOffset)
                .opacity(tabContentOpacity)
                .tag(AppTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(AppTheme.accent)
        .simultaneousGesture(tabSwipeGesture)
        .onAppear {
            DispatchQueue.main.async {
                showsResetRequest &+= 1
            }
        }
    }

    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard !isTransitioningTabs,
                      (selection != .settings || settingsAllowsTabSwipe),
                      (selection != .discover || !discoverCarouselIsInteracting),
                      abs(horizontal) >= 100,
                      abs(horizontal) > abs(vertical) * 1.5,
                      let destination = tab(inSwipeDirection: horizontal) else {
                    return
                }
                transition(to: destination, swipeTranslation: horizontal)
            }
    }

    private func tab(inSwipeDirection horizontal: CGFloat) -> AppTab? {
        if horizontal < 0 {
            switch selection {
            case .discover: return .shows
            case .shows: return .settings
            case .settings: return nil
            }
        }

        switch selection {
        case .discover: return nil
        case .shows: return .discover
        case .settings: return .shows
        }
    }

    private func select(_ newSelection: AppTab) {
        tabContentOffset = 0
        tabContentOpacity = 1
        isTransitioningTabs = false
        if newSelection == .shows {
            showsResetRequest &+= 1
        }
        selection = newSelection
    }

    private func transition(to destination: AppTab, swipeTranslation: CGFloat) {
        isTransitioningTabs = true
        let direction: CGFloat = swipeTranslation < 0 ? -1 : 1

        if destination == .shows {
            showsResetRequest &+= 1
        }

        withAnimation(.easeOut(duration: 0.11)) {
            tabContentOffset = direction * 12
            tabContentOpacity = 0.08
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(105))
            guard !Task.isCancelled, isTransitioningTabs else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = destination
                tabContentOffset = -direction * 10
                tabContentOpacity = 0.08
            }

            withAnimation(.easeOut(duration: 0.16)) {
                tabContentOffset = 0
                tabContentOpacity = 1
            }

            try? await Task.sleep(for: .milliseconds(160))
            isTransitioningTabs = false
        }
    }
}
