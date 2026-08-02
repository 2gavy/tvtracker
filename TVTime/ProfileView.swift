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
                    NavigationLink {
                        CatalogSourcesView()
                    } label: {
                        LabeledContent("Catalogs", value: TMDBClient().isConfigured ? "4 active" : "3 active")
                    }
                    LabeledContent("Stored", value: "On this iPhone")
                }
            }
            .navigationTitle("Profile")
        }
    }
}

private struct CatalogSourcesView: View {
    @State private var token = ""
    @State private var isConnected = TMDBClient().isConfigured

    var body: some View {
        Form {
            Section("Included") {
                LabeledContent("TVmaze", value: "TV schedules")
                LabeledContent("AniList", value: "Anime")
                LabeledContent("Apple", value: "Movies")
            }

            Section {
                SecureField("TMDB read access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(isConnected ? "Update TMDB connection" : "Connect TMDB") {
                    isConnected = TMDBCredentials.saveToken(token)
                    token = ""
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isConnected {
                    Button("Disconnect TMDB", role: .destructive) {
                        TMDBCredentials.deleteToken()
                        isConnected = false
                    }
                }

                Link("Get a free TMDB token", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            } header: {
                Text("Asian dramas and films")
            } footer: {
                Text("The token stays in this iPhone's Keychain and is never saved in the project.")
            }

            Section {
                HStack(spacing: 14) {
                    Image("TMDBLogo")
                        .resizable()
                        .scaledToFit()
                    .frame(width: 72, height: 28)

                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Catalogs")
        .navigationBarTitleDisplayMode(.inline)
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
