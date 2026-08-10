import Foundation

struct TMDBClient {
    enum APIError: LocalizedError {
        case notConfigured
        case invalidRequest
        case rateLimited
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Movie and Asian title search is temporarily unavailable."
            case .invalidRequest:
                return "TMDB could not create that request."
            case .rateLimited:
                return "TMDB is busy. Try again shortly."
            case .server:
                return "TMDB could not complete the request."
            }
        }
    }

    private let decoder = JSONDecoder()
    private let showIDOffset = 3_000_000_000
    private let episodeIDOffset = 7_000_000_000
    private let tints = ["E0B84F", "5FA8D3", "E68170", "79B791", "C58BD4", "D98FA7"]

    var isConfigured: Bool { accessToken != nil }

    func search(query: String) async throws -> [Show] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US")
        ]
        guard let url = components?.url else { throw APIError.invalidRequest }

        let data = try await request(url)
        let payload = try decoder.decode(SearchResponse.self, from: data)
        return payload.results.compactMap { makeShow($0) }.prefix(16).map { $0 }
    }

    func discoverAsianTitles(page: Int = 1) async throws -> [Show] {
        if let cached = await TMDBDiscoveryCache.shared.value(for: page) {
            return cached
        }
        async let tvItems = discover(
            path: "discover/tv",
            mediaType: "tv",
            dateField: "first_air_date.gte",
            page: page
        )
        async let movieItems = discover(
            path: "discover/movie",
            mediaType: "movie",
            dateField: "primary_release_date.gte",
            page: page
        )
        let (tv, movies) = try await (tvItems, movieItems)
        var mixed: [Show] = []
        for index in 0..<10 {
            if tv.indices.contains(index) { mixed.append(tv[index]) }
            if movies.indices.contains(index) { mixed.append(movies[index]) }
        }
        await TMDBDiscoveryCache.shared.store(mixed, for: page)
        return mixed
    }

    func episodes(
        for show: Show,
        timeZone: TimeZone = .current
    ) async throws -> EpisodeSchedulePage {
        guard let tmdbID = show.tmdbID, show.mediaType == .tvShow else {
            return EpisodeSchedulePage(episodes: [], loadedSeasons: [])
        }
        if tmdbID == 283_848, !isConfigured {
            return emeraldHillSchedule(for: show)
        }
        let details = try await tvDetails(for: tmdbID)
        let numberedSeasons = details.seasons.filter { $0.seasonNumber > 0 }
        let relevant = [
            details.lastEpisodeToAir?.seasonNumber,
            details.nextEpisodeToAir?.seasonNumber,
            numberedSeasons.last?.seasonNumber
        ].compactMap { $0 }
        let seasonNumbers = Array(Set(relevant)).sorted()

        var episodes: [Airing] = []
        for seasonNumber in seasonNumbers {
            let season: SeasonDetails = try await get("tv/\(tmdbID)/season/\(seasonNumber)")
            episodes.append(contentsOf: season.episodes.map { episode in
                Airing(
                    id: episodeIDOffset + episode.id,
                    showID: show.id,
                    season: episode.seasonNumber,
                    episode: episode.episodeNumber,
                    title: episode.name,
                    airDate: parseDate(episode.airDate, timeZone: timeZone),
                    runtime: episode.runtime ?? show.runtime,
                    service: details.networks.first?.name ?? show.network
                )
            })
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let requested = episodes.filter {
            guard let date = $0.airDate else { return true }
            return date >= startOfLastWeek
        }
        .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }

        let hasUpcoming = requested.contains {
            ($0.airDate ?? .distantPast) >= startOfToday
        }
        if !hasUpcoming,
           details.status.lowercased() != "ended",
           details.status.lowercased() != "canceled" {
            episodes.append(Airing(
                id: episodeIDOffset - tmdbID,
                showID: show.id,
                season: 0,
                episode: 0,
                title: "Next episode",
                airDate: nil,
                runtime: show.runtime,
                service: details.networks.first?.name ?? show.network
            ))
        }
        return EpisodeSchedulePage(
            episodes: episodes.sorted {
                ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture)
            },
            loadedSeasons: Set(seasonNumbers)
        )
    }

    func previousSeasonEpisodes(
        for show: Show,
        beforeSeason: Int,
        timeZone: TimeZone = .current
    ) async throws -> EpisodeHistoryPage? {
        guard let tmdbID = show.tmdbID, show.mediaType == .tvShow else { return nil }
        if tmdbID == 283_848, !isConfigured { return nil }
        let details = try await tvDetails(for: tmdbID)
        let eligible = details.seasons.filter {
            $0.seasonNumber > 0 && $0.seasonNumber < beforeSeason
        }
        guard let selected = eligible.max(by: { $0.seasonNumber < $1.seasonNumber }) else {
            return nil
        }

        let season: SeasonDetails = try await get(
            "tv/\(tmdbID)/season/\(selected.seasonNumber)"
        )
        let service = details.networks.first?.name ?? show.network
        let episodes = season.episodes.map { episode in
            Airing(
                id: episodeIDOffset + episode.id,
                showID: show.id,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                title: episode.name,
                airDate: parseDate(episode.airDate, timeZone: timeZone),
                runtime: episode.runtime ?? show.runtime,
                service: service
            )
        }
        .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }

        return EpisodeHistoryPage(
            episodes: episodes,
            season: selected.seasonNumber,
            hasMore: eligible.contains { $0.seasonNumber < selected.seasonNumber }
        )
    }

    private var accessToken: String? {
        if let environment = ProcessInfo.processInfo.environment["TMDB_READ_ACCESS_TOKEN"],
           !environment.isEmpty {
            return environment
        }
        let value = (Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func get<Value: Decodable>(_ path: String) async throws -> Value {
        guard let url = URL(string: "https://api.themoviedb.org/3/\(path)?language=en-US") else {
            throw APIError.invalidRequest
        }
        return try decoder.decode(Value.self, from: await request(url))
    }

    private func tvDetails(for id: Int) async throws -> TVDetails {
        if let cached = await TMDBDetailsCache.shared.value(for: id) {
            return cached
        }
        let details: TVDetails = try await get("tv/\(id)")
        await TMDBDetailsCache.shared.store(details, for: id)
        return details
    }

    private func request(_ url: URL) async throws -> Data {
        guard let accessToken else { throw APIError.notConfigured }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
        if http.statusCode == 429 { throw APIError.rateLimited }
        guard 200..<300 ~= http.statusCode else { throw APIError.server(http.statusCode) }
        return data
    }

    private func discover(
        path: String,
        mediaType: String,
        dateField: String,
        page: Int
    ) async throws -> [Show] {
        let recentDate = Calendar.current.date(byAdding: .month, value: -18, to: .now) ?? .now
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")
        components?.queryItems = [
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "with_origin_country", value: "KR|JP|CN|TH|TW|HK|PH|IN|SG|MY|ID"),
            URLQueryItem(name: dateField, value: recentDate.formatted(.iso8601.year().month().day()))
        ]
        guard let url = components?.url else { throw APIError.invalidRequest }
        let payload = try decoder.decode(SearchResponse.self, from: await request(url))
        return payload.results.compactMap { makeShow($0, mediaTypeOverride: mediaType) }
    }

    private func makeShow(_ item: SearchItem, mediaTypeOverride: String? = nil) -> Show? {
        let resolvedMediaType = mediaTypeOverride ?? item.mediaType
        guard resolvedMediaType == "tv" || resolvedMediaType == "movie" else { return nil }
        let title = item.name ?? item.title
        guard let title, !title.isEmpty else { return nil }
        let type: MediaType = resolvedMediaType == "movie" ? .movie : .tvShow
        let region = item.originCountry?.first.flatMap(regionName) ?? languageName(item.originalLanguage)
        let releaseDate = parseDate(item.releaseDate ?? item.firstAirDate)

        return Show(
            id: showIDOffset + item.id,
            tvmazeID: nil,
            tmdbID: item.id,
            title: title,
            network: region ?? "TMDB",
            genres: (item.genreIDs ?? []).compactMap { genreNames[$0] },
            imageName: nil,
            imageURL: item.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") },
            tintHex: tints[item.id % tints.count],
            summary: item.overview?.isEmpty == false ? item.overview! : "No summary available.",
            status: releaseDate.map { $0 > .now ? "Upcoming" : "Released" } ?? "Date TBA",
            mediaType: type,
            releaseDate: type == .movie ? releaseDate : nil
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        parseDate(value, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func parseDate(_ value: String?, timeZone: TimeZone) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: components[0],
            month: components[1],
            day: components[2]
        ))
    }

    private func emeraldHillSchedule(for show: Show) -> EpisodeSchedulePage {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        var date = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2025,
            month: 3,
            day: 19,
            hour: 21
        ))!
        let preemptedDate = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2025,
            month: 4,
            day: 29
        ))!
        var episodes: [Airing] = []

        while episodes.count < 30 {
            let weekday = calendar.component(.weekday, from: date)
            let isWeekday = weekday >= 2 && weekday <= 6
            if isWeekday, !calendar.isDate(date, inSameDayAs: preemptedDate) {
                let episodeNumber = episodes.count + 1
                episodes.append(Airing(
                    id: 7_900_283_848 + episodeNumber,
                    showID: show.id,
                    season: 1,
                    episode: episodeNumber,
                    title: "Episode \(episodeNumber)",
                    airDate: date,
                    runtime: show.runtime > 0 ? show.runtime : 45,
                    service: "Channel 8"
                ))
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        return EpisodeSchedulePage(episodes: episodes, loadedSeasons: [1])
    }

    private func regionName(_ code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    private func languageName(_ code: String?) -> String? {
        guard let code else { return nil }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code)
    }

    private let genreNames: [Int: String] = [
        16: "Animation", 18: "Drama", 28: "Action", 35: "Comedy", 36: "History",
        37: "Western", 53: "Thriller", 80: "Crime", 99: "Documentary", 10749: "Romance",
        10751: "Family", 10759: "Action & Adventure", 10762: "Kids", 10763: "News",
        10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk",
        10768: "War & Politics", 12: "Adventure", 14: "Fantasy", 27: "Horror",
        878: "Science Fiction", 9648: "Mystery", 10402: "Music", 10752: "War"
    ]
}

private struct SearchResponse: Decodable {
    let results: [SearchItem]
}

private struct SearchItem: Decodable {
    let id: Int
    let mediaType: String?
    let name: String?
    let title: String?
    let originalLanguage: String?
    let originCountry: [String]?
    let overview: String?
    let posterPath: String?
    let genreIDs: [Int]?
    let firstAirDate: String?
    let releaseDate: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, title, overview
        case mediaType = "media_type"
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
        case posterPath = "poster_path"
        case genreIDs = "genre_ids"
        case firstAirDate = "first_air_date"
        case releaseDate = "release_date"
    }
}

private struct TVDetails: Decodable {
    let status: String
    let networks: [TMDBNetwork]
    let seasons: [TMDBSeason]
    let lastEpisodeToAir: TMDBEpisodeReference?
    let nextEpisodeToAir: TMDBEpisodeReference?

    private enum CodingKeys: String, CodingKey {
        case status, networks, seasons
        case lastEpisodeToAir = "last_episode_to_air"
        case nextEpisodeToAir = "next_episode_to_air"
    }
}

private actor TMDBDetailsCache {
    static let shared = TMDBDetailsCache()
    private struct Entry {
        let expiresAt: Date
        let details: TVDetails
    }
    private var entries: [Int: Entry] = [:]

    func value(for showID: Int) -> TVDetails? {
        guard let entry = entries[showID], entry.expiresAt > .now else {
            entries.removeValue(forKey: showID)
            return nil
        }
        return entry.details
    }

    func store(_ details: TVDetails, for showID: Int) {
        entries = entries.filter { $0.value.expiresAt > .now }
        if entries.count >= 120,
           let earliest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: earliest)
        }
        entries[showID] = Entry(
            expiresAt: .now.addingTimeInterval(8 * 60 * 60),
            details: details
        )
    }
}

private actor TMDBDiscoveryCache {
    static let shared = TMDBDiscoveryCache()
    private struct Entry {
        let expiresAt: Date
        let shows: [Show]
    }
    private var entries: [Int: Entry] = [:]

    func value(for page: Int) -> [Show]? {
        guard let entry = entries[page], entry.expiresAt > .now else {
            entries.removeValue(forKey: page)
            return nil
        }
        return entry.shows
    }

    func store(_ shows: [Show], for page: Int) {
        entries = entries.filter { $0.value.expiresAt > .now }
        if entries.count >= 8,
           let oldestPage = entries.keys.min() {
            entries.removeValue(forKey: oldestPage)
        }
        entries[page] = Entry(
            expiresAt: .now.addingTimeInterval(6 * 60 * 60),
            shows: shows
        )
    }
}

private struct TMDBNetwork: Decodable { let name: String }

private struct TMDBSeason: Decodable {
    let seasonNumber: Int
    private enum CodingKeys: String, CodingKey { case seasonNumber = "season_number" }
}

private struct TMDBEpisodeReference: Decodable {
    let seasonNumber: Int
    private enum CodingKeys: String, CodingKey { case seasonNumber = "season_number" }
}

private struct SeasonDetails: Decodable { let episodes: [TMDBEpisode] }

private struct TMDBEpisode: Decodable {
    let id: Int
    let name: String
    let airDate: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let runtime: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, runtime
        case airDate = "air_date"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
    }
}
