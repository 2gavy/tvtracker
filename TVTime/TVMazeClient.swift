import Foundation

struct TVMazeClient {
    enum APIError: LocalizedError {
        case invalidRequest
        case rateLimited
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "That search could not be created."
            case .rateLimited:
                return "TVmaze is busy. Try again in a few seconds."
            case .server:
                return "TVmaze could not complete the request."
            }
        }
    }

    private let decoder = JSONDecoder()
    private let showIDOffset = 1_000_000_000
    private let episodeIDOffset = 2_000_000_000
    private let tints = ["FFD20F", "70B7E6", "8FCB81", "EE8C6C", "C49BE8", "E985AE"]

    func searchShows(query: String) async throws -> [Show] {
        var components = URLComponents(string: "https://api.tvmaze.com/search/shows")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw APIError.invalidRequest }

        let data = try await request(url)
        let results = try decoder.decode([SearchResultDTO].self, from: data)
        return results.prefix(20).map { makeShow($0.show) }
    }

    func matchingShow(for show: Show) async throws -> Show? {
        let requestedTitle = normalizedTitle(show.title)
        guard let match = try await searchShows(query: show.title).first(where: {
            normalizedTitle($0.title) == requestedTitle
        }), let tvmazeID = match.tvmazeID else { return nil }
        return show.withTVMazeID(tvmazeID)
    }

    func browseShows(page: Int) async throws -> [Show] {
        guard var components = URLComponents(string: "https://api.tvmaze.com/shows") else {
            throw APIError.invalidRequest
        }
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        guard let url = components.url else { throw APIError.invalidRequest }

        let data = try await request(url)
        let results = try decoder.decode([ShowDTO].self, from: data)
        return results.lazy
            .filter {
                $0.image?.medium != nil
                    && !$0.genres.isEmpty
                    && $0.type != "News"
                    && $0.type != "Sports"
            }
            .prefix(60)
            .map(makeShow)
    }

    func discoverSchedule(
        starting date: Date = .now,
        days: Int = 7,
        timeZone: TimeZone = .current
    ) async throws -> [Show] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let cacheKey = "\(timeZone.identifier):\(formatter.string(from: date)):\(days)"
        if let cached = await TVMazeDiscoveryCache.shared.value(for: cacheKey) {
            return cached
        }

        var candidates: [Int: ShowDTO] = [:]
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  var broadcastComponents = URLComponents(string: "https://api.tvmaze.com/schedule"),
                  var streamingComponents = URLComponents(string: "https://api.tvmaze.com/schedule/web") else {
                continue
            }
            let dayValue = formatter.string(from: day)
            broadcastComponents.queryItems = [
                URLQueryItem(name: "country", value: "US"),
                URLQueryItem(name: "date", value: dayValue)
            ]
            streamingComponents.queryItems = [URLQueryItem(name: "date", value: dayValue)]
            guard let broadcastURL = broadcastComponents.url,
                  let streamingURL = streamingComponents.url else { continue }

            async let broadcastData = request(broadcastURL)
            async let streamingData = request(streamingURL)
            let (broadcastPayload, streamingPayload) = try await (broadcastData, streamingData)
            let broadcasts = try decoder.decode([ScheduleEpisodeDTO].self, from: broadcastPayload)
            let streams = try decoder.decode([WebScheduleEpisodeDTO].self, from: streamingPayload)

            func addCandidate(show: ShowDTO) {
                guard show.image?.medium != nil,
                      !show.genres.isEmpty,
                      show.type != "News",
                      show.type != "Sports" else { return }
                candidates[show.id] = show
            }

            broadcasts.forEach {
                addCandidate(show: $0.show)
            }
            streams.forEach {
                addCandidate(show: $0.embedded.show)
            }
        }

        let ranked = candidates.values.sorted { left, right in
            let leftWeight = left.weight ?? 0
            let rightWeight = right.weight ?? 0
            if leftWeight != rightWeight { return leftWeight > rightWeight }
            return left.name < right.name
        }
        let result = ranked.prefix(40).map(makeShow)
        await TVMazeDiscoveryCache.shared.store(result, for: cacheKey)
        return result
    }

    func episodes(
        for show: Show,
        timeZone: TimeZone = .current
    ) async throws -> EpisodeSchedulePage {
        guard let tvmazeID = show.tvmazeID,
              let seasonsURL = URL(string: "https://api.tvmaze.com/shows/\(tvmazeID)/seasons") else {
            return EpisodeSchedulePage(episodes: [], loadedSeasons: [])
        }

        let seasons = try await seasons(for: tvmazeID, url: seasonsURL)
        let recentSeasons = seasons
            .filter { $0.number > 0 }
            .sorted { $0.number > $1.number }
            .prefix(2)
        let seasonEpisodes = try await withThrowingTaskGroup(
            of: [EpisodeDTO].self,
            returning: [[EpisodeDTO]].self
        ) { group in
            for season in recentSeasons {
                guard let episodesURL = URL(
                    string: "https://api.tvmaze.com/seasons/\(season.id)/episodes"
                ) else { continue }
                group.addTask {
                    try decoder.decode([EpisodeDTO].self, from: await request(episodesURL))
                }
            }
            var pages: [[EpisodeDTO]] = []
            for try await page in group { pages.append(page) }
            return pages
        }
        var mapped = seasonEpisodes.flatMap { episodes in
            episodes.map { makeAiring($0, show: show, timeZone: timeZone) }
        }
        mapped.sort { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfLastWeek = calendar.date(
            byAdding: .day,
            value: -7,
            to: startOfToday
        )!
        let requestedEpisodes = mapped.filter { airing in
            guard let date = airing.airDate else { return true }
            return date >= startOfLastWeek
        }
        let hasUpcoming = requestedEpisodes.contains { airing in
            guard let date = airing.airDate else { return true }
            return date >= startOfToday
        }

        if !hasUpcoming && show.status.lowercased() != "ended" {
            mapped.append(Airing(
                id: episodeIDOffset - tvmazeID,
                showID: show.id,
                season: 0,
                episode: 0,
                title: "Next episode",
                airDate: nil,
                runtime: 0,
                service: show.network
            ))
        }

        return EpisodeSchedulePage(
            episodes: mapped,
            loadedSeasons: Set(recentSeasons.map(\.number))
        )
    }

    func previousSeasonEpisodes(
        for show: Show,
        beforeSeason: Int,
        timeZone: TimeZone = .current
    ) async throws -> EpisodeHistoryPage? {
        guard let tvmazeID = show.tvmazeID,
              let seasonsURL = URL(string: "https://api.tvmaze.com/shows/\(tvmazeID)/seasons") else {
            return nil
        }

        let seasons = try await seasons(for: tvmazeID, url: seasonsURL)
        let eligible = seasons.filter { $0.number > 0 && $0.number < beforeSeason }
        guard let season = eligible.max(by: { $0.number < $1.number }),
              let episodesURL = URL(string: "https://api.tvmaze.com/seasons/\(season.id)/episodes") else {
            return nil
        }

        let items = try decoder.decode([EpisodeDTO].self, from: await request(episodesURL))
        let episodes = items
            .map { makeAiring($0, show: show, timeZone: timeZone) }
            .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }
        return EpisodeHistoryPage(
            episodes: episodes,
            season: season.number,
            hasMore: eligible.contains { $0.number < season.number }
        )
    }

    private func request(_ url: URL, canRetry: Bool = true) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.setValue("TVTracker/1.0 iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
        if http.statusCode == 429, canRetry {
            try await Task.sleep(for: .seconds(2))
            return try await self.request(url, canRetry: false)
        }
        if http.statusCode == 429 { throw APIError.rateLimited }
        guard 200..<300 ~= http.statusCode else { throw APIError.server(http.statusCode) }
        return data
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private func airDate(
        for episode: EpisodeDTO,
        show: Show,
        timeZone: TimeZone
    ) -> Date? {
        // TVMaze currently uses noon UTC placeholders for RAW and omits its airtime.
        if show.tvmazeID == 802,
           episode.airstamp?.contains("T12:00:00+00:00") == true,
           let value = episode.airdate {
            return localBroadcastDate(
                value,
                hour: 20,
                timeZoneIdentifier: "America/New_York"
            )
        }
        if let stamp = episode.airstamp {
            if let date = try? Date(stamp, strategy: .iso8601) { return date }
        }
        guard let value = episode.airdate else { return nil }
        return calendarDate(value, timeZone: timeZone)
    }

    private func seasons(for showID: Int, url: URL) async throws -> [SeasonDTO] {
        if let cached = await TVMazeSeasonCache.shared.value(for: showID) {
            return cached
        }
        let value = try decoder.decode([SeasonDTO].self, from: await request(url))
        await TVMazeSeasonCache.shared.store(value, for: showID)
        return value
    }

    private func calendarDate(_ value: String, timeZone: TimeZone) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: components[0],
            month: components[1],
            day: components[2]
        ))
    }

    private func localBroadcastDate(
        _ value: String,
        hour: Int,
        timeZoneIdentifier: String
    ) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: components[0],
            month: components[1],
            day: components[2],
            hour: hour
        ))
    }

    private func makeAiring(_ item: EpisodeDTO, show: Show, timeZone: TimeZone) -> Airing {
        Airing(
            id: episodeIDOffset + item.id,
            showID: show.id,
            season: item.season ?? 0,
            episode: item.number ?? 0,
            title: item.name,
            airDate: airDate(for: item, show: show, timeZone: timeZone),
            runtime: item.runtime ?? 0,
            service: show.network
        )
    }

    private func makeShow(_ item: ShowDTO) -> Show {
        Show(
            id: showIDOffset + item.id,
            tvmazeID: item.id,
            title: item.name,
            network: item.webChannel?.name ?? item.network?.name ?? "Network TBA",
            genres: item.genres,
            imageName: nil,
            imageURL: item.image?.medium.flatMap(URL.init(string:)),
            tintHex: tints[item.id % tints.count],
            summary: cleanSummary(item.summary),
            status: item.status
        )
    }

    private func cleanSummary(_ value: String?) -> String {
        guard let value else { return "No summary available." }
        return value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

private struct SearchResultDTO: Decodable {
    let show: ShowDTO
}

private struct ShowDTO: Decodable {
    let id: Int
    let name: String
    let type: String?
    let status: String
    let genres: [String]
    let network: ChannelDTO?
    let webChannel: ChannelDTO?
    let image: ImageDTO?
    let summary: String?
    let weight: Int?
}

private struct ScheduleEpisodeDTO: Decodable {
    let show: ShowDTO
}

private struct WebScheduleEpisodeDTO: Decodable {
    let embedded: EmbeddedShowDTO

    private enum CodingKeys: String, CodingKey {
        case embedded = "_embedded"
    }
}

private struct EmbeddedShowDTO: Decodable {
    let show: ShowDTO
}

private struct ChannelDTO: Decodable {
    let name: String
}

private struct ImageDTO: Decodable {
    let medium: String?
}

private struct EpisodeDTO: Decodable {
    let id: Int
    let name: String
    let season: Int?
    let number: Int?
    let airdate: String?
    let airstamp: String?
    let runtime: Int?
}

private struct SeasonDTO: Decodable {
    let id: Int
    let number: Int
}

private actor TVMazeSeasonCache {
    static let shared = TVMazeSeasonCache()
    private struct Entry {
        let expiresAt: Date
        let seasons: [SeasonDTO]
    }
    private var entries: [Int: Entry] = [:]

    func value(for showID: Int) -> [SeasonDTO]? {
        guard let entry = entries[showID], entry.expiresAt > .now else {
            entries.removeValue(forKey: showID)
            return nil
        }
        return entry.seasons
    }

    func store(_ seasons: [SeasonDTO], for showID: Int) {
        entries = entries.filter { $0.value.expiresAt > .now }
        if entries.count >= 120,
           let earliest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: earliest)
        }
        entries[showID] = Entry(
            expiresAt: .now.addingTimeInterval(24 * 60 * 60),
            seasons: seasons
        )
    }
}

private actor TVMazeDiscoveryCache {
    static let shared = TVMazeDiscoveryCache()
    private struct Entry {
        let expiresAt: Date
        let shows: [Show]
    }
    private var entries: [String: Entry] = [:]

    func value(for key: String) -> [Show]? {
        guard let entry = entries[key], entry.expiresAt > .now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.shows
    }

    func store(_ shows: [Show], for key: String) {
        entries = entries.filter { $0.value.expiresAt > .now }
        entries[key] = Entry(
            expiresAt: .now.addingTimeInterval(6 * 60 * 60),
            shows: shows
        )
    }
}
