import SwiftUI

struct FollowingView: View {
    @EnvironmentObject private var store: ShowStore

    var body: some View {
        Group {
            if store.followedShows.isEmpty {
                ContentUnavailableView(
                    "No subscriptions",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Browse Discover and subscribe to a few shows.")
                )
            } else {
                List(store.followedShows) { show in
                    HStack(spacing: 12) {
                        PosterView(show: show, width: 48, height: 68)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(show.title).font(.headline)
                            Text(show.network).font(.subheadline).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            withAnimation(.snappy) {
                                store.toggleFollow(show)
                            }
                        } label: {
                            Label("Unsubscribe", systemImage: "minus.circle")
                        }
                        .accessibilityLabel("Unsubscribe from \(show.title)")
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Subscribed shows")
    }
}
