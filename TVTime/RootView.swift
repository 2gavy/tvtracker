import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: ShowStore
    @AppStorage("themeMusicEnabled") private var themeMusicEnabled = true
    @State private var selection: AppTab = .shows
    @State private var isPlayerVisible = false
    @StateObject private var themePlayer = ThemeSongPlayer()

    var body: some View {
        GeometryReader { geometry in
            TabView(selection: $selection) {
                ShowsView()
                    .tag(AppTab.shows)
                    .tabItem { Label("Shows", systemImage: "play.tv.fill") }

                DiscoverView()
                    .tag(AppTab.discover)
                    .tabItem { Label("Discover", systemImage: "sparkles.tv.fill") }

                ProfileView()
                    .tag(AppTab.profile)
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            }
            .overlay(alignment: .bottom) {
                if isPlayerVisible, let song = themePlayer.currentSong {
                    NowPlayingBanner(
                        song: song,
                        isPlaying: themePlayer.isPlaying,
                        playPrevious: themePlayer.playPreviousTheme,
                        togglePlayback: themePlayer.togglePlayback,
                        playNext: { Task { await themePlayer.skipToNextTheme() } }
                    )
                    .padding(.bottom, 54)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .tint(AppTheme.accent)
        .animation(.snappy, value: isPlayerVisible)
        .task {
            if themeMusicEnabled {
                await themePlayer.autoplay(from: store.followedShows)
            }
        }
        .task(id: themePlayer.currentSong?.id) {
            guard themePlayer.currentSong != nil else {
                isPlayerVisible = false
                return
            }

            isPlayerVisible = true
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            isPlayerVisible = false
        }
        .onChange(of: themeMusicEnabled) { _, isEnabled in
            if isEnabled {
                Task { await themePlayer.autoplay(from: store.followedShows) }
            } else {
                themePlayer.disable()
                isPlayerVisible = false
            }
        }
        .onChange(of: store.followedIDs) { previousIDs, currentIDs in
            if currentIDs.isEmpty {
                themePlayer.disable()
                isPlayerVisible = false
            } else if previousIDs.isEmpty, themeMusicEnabled {
                Task { await themePlayer.autoplay(from: store.followedShows) }
            } else if themeMusicEnabled {
                Task { await themePlayer.updateSubscriptions(store.followedShows) }
            }
        }
    }
}

private struct NowPlayingBanner: View {
    let song: ThemeSong
    let isPlaying: Bool
    let playPrevious: () -> Void
    let togglePlayback: () -> Void
    let playNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.artworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.elevated)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Now Playing")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .textCase(.uppercase)

                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button(action: playPrevious) {
                    Image(systemName: "backward.end.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 38)
                }
                .accessibilityLabel("Play previous theme")

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 38)
                }
                .accessibilityLabel(isPlaying ? "Pause theme" : "Resume theme")

                Button(action: playNext) {
                    Image(systemName: "forward.end.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 38)
                }
                .accessibilityLabel("Play next theme")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }
}
