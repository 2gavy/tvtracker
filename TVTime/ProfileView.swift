import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: ShowStore
    @AppStorage("episodeReminders") private var reminders = true
    @AppStorage("spoilerProtection") private var spoilerProtection = true
    @AppStorage("darkModeEnabled") private var darkModeEnabled = true
    @AppStorage("themeMusicEnabled") private var themeMusicEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        FollowingView()
                    } label: {
                        LabeledContent("Subscribed shows", value: "\(store.followedShows.count)")
                    }

                    NavigationLink {
                        WatchedEpisodesView()
                    } label: {
                        LabeledContent("Episodes watched", value: "\(store.watchedAiringIDs.count)")
                    }

                    LabeledContent("Watched hours", value: store.watchedDuration)
                }

                Section("Notifications") {
                    Toggle("Episode reminders", isOn: $reminders)
                    Toggle("Hide episode titles until aired", isOn: $spoilerProtection)
                }

                Section("Appearance") {
                    Toggle("Dark mode", systemImage: "circle.lefthalf.filled", isOn: $darkModeEnabled)
                }

                Section("Playback") {
                    Toggle("Theme music", systemImage: "music.note", isOn: $themeMusicEnabled)
                }

                Section("Data") {
                    LabeledContent("Schedule", value: "TVmaze")
                    LabeledContent("Stored", value: "On this iPhone")
                }
            }
            .navigationTitle("Profile")
        }
    }
}

private struct WatchedEpisodesView: View {
    @EnvironmentObject private var store: ShowStore

    var body: some View {
        Group {
            if store.watchedAirings.isEmpty {
                ContentUnavailableView(
                    "No watched episodes",
                    systemImage: "checkmark.circle",
                    description: Text("Episodes you mark as watched will appear here.")
                )
            } else {
                List(store.watchedAirings) { airing in
                    AiringRow(airing: airing)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Episodes watched")
    }
}
