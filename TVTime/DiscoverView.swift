import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: ShowStore
    @State private var query = ""
    @State private var searchResults: [Show] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var asianHighlights: [Show] = []
    @State private var mediaFilter: MediaFilter = .all
    @State private var providerFilter = "All services"
    @State private var selectedShow: Show?

    private let providers = ["All services", "Netflix", "Apple TV+", "Hulu", "Max", "Disney+", "Prime Video", "HBO"]
    private let client = TVMazeClient()
    private let movieClient = AppleMovieClient()
    private let tmdbClient = TMDBClient()
    private let aniListClient = AniListClient()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesProvider(_ network: String) -> Bool {
        let value = network.lowercased()
        switch providerFilter {
        case "Apple TV+": return value == "apple tv+"
        case "Hulu": return value.contains("hulu")
        case "Max": return value == "max"
        case "Prime Video": return value.contains("prime video") || value.contains("amazon")
        default: return value.contains(providerFilter.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    browseContent
                } else {
                    searchContent
                }
            }
            .navigationTitle("Discover")
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Type") {
                            Picker("Media type", selection: $mediaFilter) {
                                ForEach(MediaFilter.allCases) { filter in
                                    Label(filter.title, systemImage: filter.systemImage)
                                        .tag(filter)
                                }
                            }
                        }

                        Section("Service") {
                            Picker("Service", selection: $providerFilter) {
                                ForEach(providers, id: \.self) { provider in
                                    Text(provider).tag(provider)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: filtersAreActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Filter discover")
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search shows and movies"
            )
            .task(id: trimmedQuery) {
                await search()
            }
            .task(id: tmdbClient.isConfigured) {
                await loadAsianHighlights()
            }
        }
        .fullScreenCover(item: $selectedShow) { show in
            ShowDetailView(show: show)
        }
    }

    private var browseContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 3_600)) { context in
                    let shows = trendingShows(for: context.date)
                    let trendingIDs = Set(shows.map(\.id))
                    let recommendations = recommendedShows(
                        for: context.date,
                        excluding: trendingIDs
                    )

                    VStack(alignment: .leading, spacing: 28) {
                        if shows.isEmpty {
                            ContentUnavailableView(
                                "No matching titles",
                                systemImage: "play.tv"
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            TrendingCarousel(shows: shows, onSelect: { selectedShow = $0 })
                        }

                        if !recommendations.isEmpty {
                            RecommendationsCarousel(shows: recommendations, onSelect: { selectedShow = $0 })
                        }

                        let asianMatches = asianHighlights.filter { show in
                            mediaFilter.includes(show)
                                && (providerFilter == "All services" || matchesProvider(show.network))
                        }
                        if !asianMatches.isEmpty {
                            AsianHighlightsCarousel(shows: asianMatches, onSelect: { selectedShow = $0 })
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func trendingShows(for date: Date) -> [Show] {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let daySeed = UInt64(
            (components.year ?? 0) * 10_000
                + (components.month ?? 0) * 100
                + (components.day ?? 0)
        )
        var generator = DailyRandomNumberGenerator(state: daySeed)
        let matches = store.shows.filter { show in
            mediaFilter.includes(show)
                && (providerFilter == "All services" || matchesProvider(show.network))
        }
        return Array(matches.shuffled(using: &generator).prefix(8))
    }

    private var filtersAreActive: Bool {
        mediaFilter != .all || providerFilter != "All services"
    }

    private func recommendedShows(for date: Date, excluding excludedIDs: Set<Int>) -> [Show] {
        let followed = store.followedShows
        let followedGenres = followed.flatMap(\.genres)
        let genreWeights = Dictionary(followedGenres.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        let followedNetworks = Set(followed.map { $0.network.lowercased() })
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let daySeed = UInt64(
            (components.year ?? 0) * 10_000
                + (components.month ?? 0) * 100
                + (components.day ?? 0)
                + 97
        )
        var generator = DailyRandomNumberGenerator(state: daySeed)
        let candidates = store.shows.filter { show in
            !store.isFollowing(show)
                && !excludedIDs.contains(show.id)
                && mediaFilter.includes(show)
                && (providerFilter == "All services" || matchesProvider(show.network))
        }

        func affinityScore(for show: Show) -> Int {
            let genreScore = show.genres.reduce(0) { result, genre in
                result + (genreWeights[genre.lowercased()] ?? 0) * 3
            }
            let networkScore = followedNetworks.contains(show.network.lowercased()) ? 2 : 0
            return genreScore + networkScore
        }

        return Array(
            candidates
                .shuffled(using: &generator)
                .sorted { affinityScore(for: $0) > affinityScore(for: $1) }
                .prefix(8)
        )
    }

    @ViewBuilder
    private var searchContent: some View {
        if isSearching && searchResults.isEmpty {
            ProgressView("Searching catalogs")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError, searchResults.isEmpty {
            ContentUnavailableView(
                "Search unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(searchError)
            )
        } else if searchResults.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List(searchResults) { show in
                SearchResultRow(show: show, onSelect: { selectedShow = $0 })
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func search() async {
        guard !trimmedQuery.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }

        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(350))
            var results = store.shows.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedQuery)
            }
            var lastError: Error?
            do {
                results.append(contentsOf: try await client.searchShows(query: trimmedQuery))
            } catch {
                lastError = error
            }
            do {
                results.append(contentsOf: try await movieClient.searchMovies(query: trimmedQuery))
            } catch {
                lastError = error
            }
            if tmdbClient.isConfigured {
                do {
                    results.append(contentsOf: try await tmdbClient.search(query: trimmedQuery))
                } catch {
                    lastError = error
                }
            }
            do {
                results.append(contentsOf: try await aniListClient.searchAnime(query: trimmedQuery))
            } catch {
                lastError = error
            }
            if results.isEmpty, let lastError { throw lastError }
            guard !Task.isCancelled else { return }
            var seen: Set<String> = []
            searchResults = results.filter { show in
                let key = "\(show.mediaType.rawValue):\(show.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
                return mediaFilter.includes(show)
                    && (providerFilter == "All services" || matchesProvider(show.network))
                    && seen.insert(key).inserted
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    private func loadAsianHighlights() async {
        guard tmdbClient.isConfigured else {
            asianHighlights = []
            return
        }
        do {
            asianHighlights = try await tmdbClient.discoverAsianTitles()
        } catch {
            asianHighlights = []
        }
    }
}

private struct DailyRandomNumberGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

private struct TrendingCarousel: View {
    let shows: [Show]
    let onSelect: (Show) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Trending")
                .font(.title3.weight(.bold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 13) {
                    ForEach(shows) { show in
                        TrendingCard(show: show, onSelect: onSelect)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct TrendingCard: View {
    @EnvironmentObject private var store: ShowStore
    let show: Show
    let onSelect: (Show) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterView(show: show, width: 132, height: 190)

            Text(show.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 5) {
                Text(show.network)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Button {
                    withAnimation(.snappy) { store.toggleFollow(show) }
                } label: {
                    Image(systemName: store.isFollowing(show) ? "checkmark" : "plus")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .tint(store.isFollowing(show) ? AppTheme.accent : Color.primary)
                .accessibilityLabel(store.isFollowing(show) ? "Unsubscribe from \(show.title)" : "Subscribe to \(show.title)")
            }
        }
        .frame(width: 132)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(show) }
        .accessibilityAction(named: "Show details") { onSelect(show) }
    }
}

private struct RecommendationsCarousel: View {
    let shows: [Show]
    let onSelect: (Show) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For you")
                .font(.title3.weight(.bold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(shows) { show in
                        RecommendationCard(show: show, onSelect: onSelect)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct AsianHighlightsCarousel: View {
    let shows: [Show]
    let onSelect: (Show) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Across Asia")
                .font(.title3.weight(.bold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 13) {
                    ForEach(shows) { show in
                        TrendingCard(show: show, onSelect: onSelect)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct RecommendationCard: View {
    @EnvironmentObject private var store: ShowStore
    let show: Show
    let onSelect: (Show) -> Void

    var body: some View {
        HStack(spacing: 11) {
            PosterView(show: show, width: 82, height: 118)

            VStack(alignment: .leading, spacing: 6) {
                Text(show.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(show.network)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                if !show.genres.isEmpty {
                    Text(show.genres.prefix(2).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                Button {
                    withAnimation(.snappy) { store.toggleFollow(show) }
                } label: {
                    Label("Subscribe", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.primary)
                .accessibilityLabel("Subscribe to \(show.title)")
            }
        }
        .padding(8)
        .frame(width: 268, height: 134)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(show) }
        .accessibilityAction(named: "Show details") { onSelect(show) }
    }
}

private struct SearchResultRow: View {
    @EnvironmentObject private var store: ShowStore
    let show: Show
    let onSelect: (Show) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PosterView(show: show, width: 58, height: 84)

            VStack(alignment: .leading, spacing: 5) {
                Text(show.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(show.network)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                if !show.genres.isEmpty {
                    Text(show.genres.prefix(2).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if store.isLoadingSchedule(for: show) {
                ProgressView()
                    .tint(AppTheme.accent)
                    .frame(width: 44, height: 44)
            } else {
                Button {
                    store.toggleFollow(show)
                } label: {
                    Image(systemName: store.isFollowing(show) ? "checkmark" : "plus")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(store.isFollowing(show) ? AppTheme.accent : Color.primary)
                .accessibilityLabel(store.isFollowing(show) ? "Unsubscribe from \(show.title)" : "Subscribe to \(show.title)")
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(show) }
        .accessibilityAction(named: "Show details") { onSelect(show) }
    }
}

private struct ShowDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShowStore
    let show: Show

    private var releaseText: String? {
        guard let releaseDate = show.releaseDate else { return nil }
        return releaseDate.formatted(.dateTime.day().month(.abbreviated).year())
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    DetailPoster(show: show)
                        .containerRelativeFrame(.horizontal)
                        .containerRelativeFrame(.vertical) { length, _ in
                            length * 0.48
                        }

                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(show.title)
                                .font(.largeTitle.weight(.bold))
                                .foregroundStyle(.white)

                            HStack(spacing: 7) {
                                Label(show.mediaType == .movie ? "Movie" : "Series", systemImage: show.mediaType.systemImage)
                                if let releaseText { Text(releaseText) }
                                if show.runtime > 0 { Text("\(show.runtime) min") }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.68))

                            Text(show.network)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)

                            if !show.genres.isEmpty {
                                Text(show.genres.joined(separator: "  ·  "))
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                        }

                        Divider().overlay(.white.opacity(0.18))

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Synopsis")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text(show.summary)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineSpacing(5)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 130)
                }
            }
            .scrollIndicators(.hidden)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.top, 12)
            .padding(.trailing, 16)
            .accessibilityLabel("Close details")
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                withAnimation(.snappy) { store.toggleFollow(show) }
            } label: {
                Label(
                    store.isFollowing(show) ? "Subscribed" : "Subscribe",
                    systemImage: store.isFollowing(show) ? "checkmark" : "plus"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(.ultraThinMaterial)
        }
        .statusBarHidden()
    }
}

private struct DetailPoster: View {
    let show: Show

    var body: some View {
        ZStack {
            Color(hex: show.tintHex).opacity(0.18)

            if let imageName = show.imageName,
               let path = Bundle.main.path(forResource: imageName, ofType: "jpg", inDirectory: "Posters"),
               let poster = UIImage(contentsOfFile: path) {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
            } else if let imageURL = show.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        ProgressView().tint(AppTheme.accent)
                    }
                }
            } else {
                Image(systemName: "play.tv")
                    .font(.system(size: 54))
                    .foregroundStyle(Color(hex: show.tintHex))
            }
        }
    }
}
