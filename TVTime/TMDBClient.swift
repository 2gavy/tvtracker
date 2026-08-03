import Foundation
import Security

struct TMDBClient {
    enum APIError: LocalizedError {
        case notConfigured
        case invalidRequest
        case rateLimited
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Add a free TMDB read token to enable Asian drama and film search."
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

    func discoverAsianTitles() async throws -> [Show] {
        async let tvItems = discover(
            path: "discover/tv",
            mediaType: "tv",
            dateField: "first_air_date.gte"
        )
        async let movieItems = discover(
            path: "discover/movie",
            mediaType: "movie",
            dateField: "primary_release_date.gte"
        )
        let (tv, movies) = try await (tvItems, movieItems)
        var mixed: [Show] = []
        for index in 0..<10 {
            if tv.indices.contains(index) { mixed.append(tv[index]) }
            if movies.indices.contains(index) { mixed.append(movies[index]) }
        }
        return mixed
    }

    func episodes(
        for show: Show,
        includingHistory: Bool = false,
        timeZone: TimeZone = .current
    ) async throws -> [Airing] {
        guard let tmdbID = show.tmdbID, show.mediaType == .tvShow else { return [] }
        let details: TVDetails = try await get("tv/\(tmdbID)")
        let numberedSeasons = details.seasons.filter { $0.seasonNumber > 0 }
        let seasonNumbers: [Int]

        if includingHistory {
            seasonNumbers = numberedSeasons.map(\.seasonNumber)
        } else {
            let relevant = [
                details.lastEpisodeToAir?.seasonNumber,
                details.nextEpisodeToAir?.seasonNumber,
                numberedSeasons.last?.seasonNumber
            ].compactMap { $0 }
            seasonNumbers = Array(Set(relevant)).sorted()
        }

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
                    airDate: parseDate(episode.airDate),
                    runtime: episode.runtime ?? show.runtime,
                    service: details.networks.first?.name ?? show.network
                )
            })
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let requested = includingHistory ? episodes : episodes.filter {
            guard let date = $0.airDate else { return true }
            return date >= startOfLastWeek
        }
        .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }

        if requested.contains(where: { ($0.airDate ?? .distantPast) >= startOfToday }) {
            return requested
        }
        if details.status.lowercased() != "ended" && details.status.lowercased() != "canceled" {
            return [Airing(
                id: episodeIDOffset - tmdbID,
                showID: show.id,
                season: 0,
                episode: 0,
                title: "Next episode",
                airDate: nil,
                runtime: show.runtime,
                service: details.networks.first?.name ?? show.network
            )] + requested
        }
        return requested
    }

    private var accessToken: String? {
        if let stored = TMDBCredentials.loadToken(), !stored.isEmpty { return stored }
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

    private func request(_ url: URL) async throws -> Data {
        guard let accessToken else { throw APIError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
        if http.statusCode == 429 { throw APIError.rateLimited }
        guard 200..<300 ~= http.statusCode else { throw APIError.server(http.statusCode) }
        return data
    }

    private func discover(path: String, mediaType: String, dateField: String) async throws -> [Show] {
        let recentDate = Calendar.current.date(byAdding: .month, value: -18, to: .now) ?? .now
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")
        components?.queryItems = [
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
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
            imageURL: item.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") },
            tintHex: tints[item.id % tints.count],
            summary: item.overview?.isEmpty == false ? item.overview! : "No summary available.",
            status: releaseDate.map { $0 > .now ? "Upcoming" : "Released" } ?? "Date TBA",
            mediaType: type,
            releaseDate: type == .movie ? releaseDate : nil
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
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

enum TMDBCredentials {
    private static let service = "com.zingzailoo.tvtracker.tmdb"
    private static let account = "read-access-token"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteToken()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
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
