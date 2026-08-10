import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: ShowStore
    let isActive: Bool
    @Binding var carouselIsInteracting: Bool
    @State private var query = ""
    @State private var catalogSearchResults: [Show] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var liveShows: [Show] = []
    @State private var trendingAnime: [Show] = []
    @State private var asianHighlights: [Show] = []
    @State private var catalogShows: [Show] = []
    @State private var isLoadingDiscovery = false
    @State private var isLoadingMoreDiscovery = false
    @State private var catalogPage = 0
    @State private var asianPage = 1
    @State private var discoveryGeneration = 0
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var carouselReleaseTask: Task<Void, Never>?
    @State private var mediaFilter: MediaFilter = .all
    @State private var providerFilter = "All services"
    @State private var genreFilter = "All"
    @State private var selectedShow: Show?

    private let providers = [
        "All services", "Netflix", "Apple TV+", "Hulu", "Max", "Disney+",
        "Prime Video", "Paramount+", "Peacock", "meWATCH", "Channel 5",
        "Channel 8", "CBS", "NBC", "ABC", "HBO"
    ]
    private let genres = ["All", "Drama", "Comedy", "Reality", "Crime", "Action", "Sci-Fi", "Anime"]
    private let client = TVMazeClient()
    private let tmdbClient = TMDBClient()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [Show] {
        catalogSearchResults.filter { show in
            mediaFilter.includes(show)
                && (providerFilter == "All services" || matchesProvider(show.network))
        }
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
            .onChange(of: trimmedQuery) { oldValue, newValue in
                guard oldValue.isEmpty, !newValue.isEmpty else { return }
                mediaFilter = .all
                providerFilter = "All services"
            }
            .task(id: isActive) {
                guard isActive else { return }
                async let discovery: Void = loadDiscovery()
                async let asian: Void = loadAsianHighlights()
                _ = await (discovery, asian)
            }
            .onChange(of: isActive) { _, active in
                if !active {
                    loadMoreTask?.cancel()
                    loadMoreTask = nil
                    releaseDiscoveryContent()
                }
            }
        }
        .fullScreenCover(item: $selectedShow) { show in
            ShowDetailView(show: show)
        }
        .environment(\.carouselInteractionChanged, updateCarouselInteraction)
    }

    private var browseContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                GenreTabs(genres: genres, selection: $genreFilter)

                if isLoadingDiscovery && liveShows.isEmpty {
                    ProgressView("Finding something good")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 64)
                } else {
                    let trending = filteredBrowseShows(liveShows + catalogShows)
                    let recommendations = recommendedShows(
                        for: .now,
                        candidates: discoveryCandidates
                    )
                    let anime = filteredBrowseShows(
                        trendingAnime + catalogShows.filter(isAnimeCandidate)
                    )
                    let asian = filteredBrowseShows(asianHighlights)
                    let local = filteredBrowseShows(MediacorpCatalog.shows)

                    if !trending.isEmpty {
                        PosterCarousel(
                            title: "Trending",
                            shows: trending,
                            generation: discoveryGeneration,
                            onLoadMore: requestMoreDiscovery,
                            onSelect: { selectedShow = $0 }
                        )
                    }

                    if !recommendations.isEmpty {
                        RecommendationsCarousel(
                            shows: recommendations,
                            generation: discoveryGeneration,
                            onLoadMore: requestMoreDiscovery,
                            onSelect: { selectedShow = $0 }
                        )
                    }

                    if !anime.isEmpty, genreFilter == "All" || genreFilter == "Anime" {
                        PosterCarousel(
                            title: "Anime & animation",
                            shows: anime,
                            generation: discoveryGeneration,
                            onLoadMore: requestMoreDiscovery,
                            onSelect: { selectedShow = $0 }
                        )
                    }

                    if !asian.isEmpty {
                        PosterCarousel(
                            title: "Across Asia",
                            shows: asian,
                            generation: discoveryGeneration,
                            onLoadMore: requestMoreDiscovery,
                            onSelect: { selectedShow = $0 }
                        )
                    }

                    if !local.isEmpty {
                        PosterCarousel(
                            title: "Made in Singapore",
                            shows: local,
                            generation: 0,
                            onLoadMore: {},
                            onSelect: { selectedShow = $0 }
                        )
                    }

                    if trending.isEmpty,
                       recommendations.isEmpty,
                       anime.isEmpty,
                       asian.isEmpty,
                       local.isEmpty {
                        ContentUnavailableView(
                            "No matching titles",
                            systemImage: "play.tv"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await loadDiscovery()
            await loadAsianHighlights()
        }
    }

    private var filtersAreActive: Bool {
        mediaFilter != .all || providerFilter != "All services"
    }

    private var discoveryCandidates: [Show] {
        var seen: Set<Int> = []
        return (liveShows + trendingAnime + asianHighlights + catalogShows
            + MediacorpCatalog.shows + store.shows)
            .filter { seen.insert($0.id).inserted }
    }

    private func filteredBrowseShows(_ shows: [Show]) -> [Show] {
        var seen: Set<String> = []
        return shows.filter { show in
            let key = discoveryKey(show)
            return seen.insert(key).inserted
                && mediaFilter.includes(show)
                && (providerFilter == "All services" || matchesProvider(show.network))
                && matchesGenre(show)
        }
    }

    private func matchesGenre(_ show: Show) -> Bool {
        guard genreFilter != "All" else { return true }
        if genreFilter == "Sci-Fi" {
            return show.genres.contains { $0.localizedCaseInsensitiveContains("science fiction") }
        }
        return show.genres.contains { $0.localizedCaseInsensitiveCompare(genreFilter) == .orderedSame }
    }

    private func isAnimeCandidate(_ show: Show) -> Bool {
        let network = show.network.lowercased()
        return show.genres.contains {
            $0.localizedCaseInsensitiveContains("animation")
                || $0.localizedCaseInsensitiveCompare("Anime") == .orderedSame
        } || ["tokyo", "ntv", "mbs", "fuji", "tv asahi"].contains {
            network.contains($0)
        }
    }

    private func recommendedShows(
        for date: Date,
        candidates: [Show]
    ) -> [Show] {
        let followed = store.followedShows
        let followedGenres = followed.flatMap(\.genres)
        let genreWeights = Dictionary(followedGenres.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        let followedNetworks = Set(followed.map { $0.network.lowercased() })
        let components = store.calendar.dateComponents([.year, .month, .day], from: date)
        let daySeed = UInt64(
            (components.year ?? 0) * 10_000
                + (components.month ?? 0) * 100
                + (components.day ?? 0)
                + 97
        )
        let matches = candidates.filter { show in
            !store.isFollowing(show)
                && mediaFilter.includes(show)
                && (providerFilter == "All services" || matchesProvider(show.network))
                && matchesGenre(show)
        }

        func affinityScore(for show: Show) -> Int {
            let genreScore = show.genres.reduce(0) { result, genre in
                result + (genreWeights[genre.lowercased()] ?? 0) * 3
            }
            let networkScore = followedNetworks.contains(show.network.lowercased()) ? 2 : 0
            return genreScore + networkScore
        }

        let ranked: [RankedRecommendation] = matches.map { show in
            RankedRecommendation(
                show: show,
                score: affinityScore(for: show),
                rank: dailyRank(showID: show.id, seed: daySeed)
            )
        }
        return ranked.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.rank < right.rank
        }.map(\.show)
    }

    private func dailyRank(showID: Int, seed: UInt64) -> UInt64 {
        var value = UInt64(bitPattern: Int64(showID)) &+ seed &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
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
        } else if searchResults.isEmpty, !catalogSearchResults.isEmpty {
            ContentUnavailableView(
                "No matches with these filters",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Clear the type or service filter to see all catalog matches.")
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
            catalogSearchResults = []
            searchError = nil
            isSearching = false
            return
        }

        isSearching = true
        searchError = nil
        catalogSearchResults = []
        do {
            try await Task.sleep(for: .milliseconds(350))
            var results = (MediacorpCatalog.shows + store.shows).filter {
                $0.title.localizedCaseInsensitiveContains(trimmedQuery)
            }
            var lastError: Error?
            do {
                results.append(contentsOf: try await client.searchShows(query: trimmedQuery))
                guard !Task.isCancelled else { return }
                catalogSearchResults = preparedSearchResults(results)
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
            if results.isEmpty, let lastError { throw lastError }
            guard !Task.isCancelled else { return }
            catalogSearchResults = preparedSearchResults(results)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            catalogSearchResults = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    private func preparedSearchResults(_ results: [Show]) -> [Show] {
        var seen: Set<String> = []
        let unique = results.filter { show in
            let foldedTitle = show.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert("\(show.mediaType.rawValue):\(foldedTitle)").inserted
        }
        let foldedQuery = trimmedQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let ranked: [RankedSearchResult] = unique.enumerated().map { offset, show in
            RankedSearchResult(
                show: show,
                offset: offset,
                rank: searchRank(show.title, query: foldedQuery)
            )
        }
        return ranked.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.offset < right.offset
        }.map(\.show)
    }

    private func searchRank(_ title: String, query: String) -> Int {
        let foldedTitle = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if foldedTitle == query { return 0 }
        if foldedTitle.hasPrefix(query) { return 1 }
        if foldedTitle.contains(query) { return 2 }
        return 3
    }

    private func loadAsianHighlights() async {
        guard tmdbClient.isConfigured else {
            asianHighlights = []
            return
        }
        do {
            let incoming = try await tmdbClient.discoverAsianTitles(page: 1)
            guard isActive, !Task.isCancelled else { return }
            asianHighlights = incoming
            asianPage = 2
        } catch {
            guard isActive else { return }
            asianHighlights = []
        }
    }

    private func loadDiscovery() async {
        isLoadingDiscovery = true
        async let scheduleResult: [Show]? = try? await client.discoverSchedule(
            timeZone: store.timeZone
        )
        let schedule = await scheduleResult
        guard isActive, !Task.isCancelled else { return }
        liveShows = schedule ?? []
        catalogShows = []
        catalogPage = 0
        discoveryGeneration &+= 1
        trendingAnime = liveShows.filter { show in
            isAnimeCandidate(show)
        }
        isLoadingDiscovery = false
    }

    private func releaseDiscoveryContent() {
        liveShows = []
        trendingAnime = []
        asianHighlights = []
        catalogShows = []
        isLoadingDiscovery = false
        isLoadingMoreDiscovery = false
        catalogPage = 0
        asianPage = 1
        discoveryGeneration &+= 1
    }

    private func requestMoreDiscovery() {
        guard isActive, loadMoreTask == nil else { return }
        loadMoreTask = Task {
            await loadMoreDiscovery()
            loadMoreTask = nil
        }
    }

    private func loadMoreDiscovery() async {
        guard isActive, !isLoadingMoreDiscovery else { return }
        isLoadingMoreDiscovery = true
        defer { isLoadingMoreDiscovery = false }

        async let catalogResult: [Show]? = try? await client.browseShows(page: catalogPage)
        async let asianResult: [Show]? = tmdbClient.isConfigured
            ? (try? await tmdbClient.discoverAsianTitles(page: asianPage))
            : nil

        let (catalog, asian) = await (catalogResult, asianResult)
        guard isActive, !Task.isCancelled else { return }
        if let catalog, !catalog.isEmpty {
            catalogShows = appendingUnique(catalog, to: catalogShows)
            catalogPage += 1
        } else {
            catalogPage = 0
        }
        if let asian, !asian.isEmpty {
            asianHighlights = appendingUnique(asian, to: asianHighlights)
            asianPage += 1
        } else {
            asianPage = 1
        }
        discoveryGeneration &+= 1
    }

    private func appendingUnique(_ incoming: [Show], to existing: [Show]) -> [Show] {
        var result = existing
        var keys = Set(existing.map(discoveryKey))
        result.append(contentsOf: incoming.filter { keys.insert(discoveryKey($0)).inserted })
        if result.count > 360 {
            result = Array(result.suffix(300))
        }
        return result
    }

    private func discoveryKey(_ show: Show) -> String {
        let title = show.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return "\(show.mediaType.rawValue):\(title)"
    }

    private func updateCarouselInteraction(_ isInteracting: Bool) {
        carouselReleaseTask?.cancel()
        if isInteracting {
            carouselIsInteracting = true
            return
        }
        carouselReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            carouselIsInteracting = false
        }
    }
}

private struct CarouselInteractionKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

private extension EnvironmentValues {
    var carouselInteractionChanged: (Bool) -> Void {
        get { self[CarouselInteractionKey.self] }
        set { self[CarouselInteractionKey.self] = newValue }
    }
}

private extension View {
    func shieldsTabSwipeWhileDragging() -> some View {
        modifier(CarouselSwipeShield())
    }
}

private struct CarouselSwipeShield: ViewModifier {
    @Environment(\.carouselInteractionChanged) private var interactionChanged

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    interactionChanged(true)
                }
                .onEnded { _ in interactionChanged(false) }
        )
    }
}

private enum MediacorpCatalog {
    static let shows = [
        Show(
            id: 3_000_283_848,
            tvmazeID: nil,
            tmdbID: 283_848,
            title: "Emerald Hill - The Little Nyonya Story",
            network: "Channel 8",
            genres: ["Drama", "Romance", "History"],
            imageName: nil,
            imageURL: URL(string: "https://media.themoviedb.org/t/p/w500/rY3Ppmb9TNa8nh3zoTE3Prk10J3.jpg"),
            tintHex: "C99B55",
            summary: "Three generations of women navigate family secrets, identity and survival in a Peranakan household.",
            status: "Ended",
            runtime: 46
        ),
        Show(
            id: 1_000_048_998,
            tvmazeID: 48_998,
            title: "The Little Nyonya",
            network: "Channel 8",
            genres: ["Drama", "Romance", "History"],
            imageName: nil,
            imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/263/659096.jpg"),
            tintHex: "D6A85F",
            summary: "A determined young Nyonya fights prejudice and hardship while rebuilding her family's fortunes.",
            status: "Ended",
            runtime: 45
        ),
        Show(
            id: 1_000_056_970,
            tvmazeID: 56_970,
            title: "Titoudao",
            network: "meWATCH",
            genres: ["Drama", "History"],
            imageName: nil,
            imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/350/875753.jpg"),
            tintHex: "C9574F",
            summary: "A village girl rises through grit and talent to become a celebrated wayang performer.",
            status: "Ended",
            runtime: 45
        ),
        Show(
            id: 1_000_056_866,
            tvmazeID: 56_866,
            title: "Last Madame",
            network: "meWATCH",
            genres: ["Drama", "Mystery", "History"],
            imageName: nil,
            imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/406/1017163.jpg"),
            tintHex: "8E5A65",
            summary: "A banker inherits a shophouse and uncovers her great-grandmother's hidden life in 1940s Singapore.",
            status: "Ended",
            runtime: 45
        ),
        Show(
            id: 1_000_017_030,
            tvmazeID: 17_030,
            title: "Tanglin",
            network: "Channel 5",
            genres: ["Drama", "Family"],
            imageName: nil,
            imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/57/143061.jpg"),
            tintHex: "5C9F8B",
            summary: "Four multiracial families share the everyday joys and complications of life in a Singapore neighbourhood.",
            status: "Ended",
            runtime: 30
        )
    ]
}

private struct RankedRecommendation {
    let show: Show
    let score: Int
    let rank: UInt64
}

private struct RankedSearchResult {
    let show: Show
    let offset: Int
    let rank: Int
}

private struct GenreTabs: View {
    let genres: [String]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(genres, id: \.self) { genre in
                    Button {
                        withAnimation(.snappy) { selection = genre }
                    } label: {
                        VStack(spacing: 6) {
                            Text(genre)
                                .font(.subheadline.weight(selection == genre ? .bold : .medium))
                                .foregroundStyle(selection == genre ? Color.primary : Color.secondary)
                            Capsule()
                                .fill(selection == genre ? AppTheme.accent : Color.clear)
                                .frame(height: 3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .shieldsTabSwipeWhileDragging()
    }
}

private struct PosterCarousel: View {
    let title: String
    let shows: [Show]
    let generation: Int
    let onLoadMore: () -> Void
    let onSelect: (Show) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.title3.weight(.bold))

            EndlessShowScroll(
                shows: shows,
                spacing: 13,
                generation: generation,
                onLoadMore: onLoadMore
            ) { show in
                TrendingCard(show: show, onSelect: onSelect)
            }
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
    let generation: Int
    let onLoadMore: () -> Void
    let onSelect: (Show) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For you")
                .font(.title3.weight(.bold))

            EndlessShowScroll(
                shows: shows,
                spacing: 12,
                generation: generation,
                onLoadMore: onLoadMore
            ) { show in
                RecommendationCard(show: show, onSelect: onSelect)
            }
        }
    }
}

private struct EndlessShowScroll<Content: View>: View {
    let shows: [Show]
    let spacing: CGFloat
    let generation: Int
    let onLoadMore: () -> Void
    @ViewBuilder let content: (Show) -> Content
    @State private var lastRequestedGeneration = -1

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(shows) { show in
                    content(show)
                        .onAppear {
                            requestMoreIfNeeded(showID: show.id)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .shieldsTabSwipeWhileDragging()
    }

    private func requestMoreIfNeeded(showID: Int) {
        guard !shows.isEmpty,
              shows.suffix(4).contains(where: { $0.id == showID }),
              lastRequestedGeneration != generation else { return }
        lastRequestedGeneration = generation
        onLoadMore()
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
        return store.formattedReleaseDate(releaseDate)
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
                CachedPosterImage(url: imageURL, contentMode: .fit, maxPixelSize: 480) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 54))
                        .foregroundStyle(Color(hex: show.tintHex))
                }
            } else {
                Image(systemName: "play.tv")
                    .font(.system(size: 54))
                    .foregroundStyle(Color(hex: show.tintHex))
            }
        }
    }
}
