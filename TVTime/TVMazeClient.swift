import Foundation

struct TVMazeDiscovery {
    let airingSoon: [Show]
    let premieres: [Show]
}

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

    func discoverSchedule(
        starting date: Date = .now,
        days: Int = 7,
        timeZone: TimeZone = .current
    ) async throws -> TVMazeDiscovery {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var candidates: [Int: DiscoveryCandidate] = [:]
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

            func addCandidate(show: ShowDTO, season: Int?, number: Int?) {
                guard show.image?.medium != nil,
                      !show.genres.isEmpty,
                      show.type != "News",
                      show.type != "Sports" else { return }
                let candidate = DiscoveryCandidate(
                    show: show,
                    isPremiere: season == 1 && (number ?? 0) <= 2
                )
                if let existing = candidates[show.id] {
                    candidates[show.id] = DiscoveryCandidate(
                        show: existing.show,
                        isPremiere: existing.isPremiere || candidate.isPremiere
                    )
                } else {
                    candidates[show.id] = candidate
                }
            }

            broadcasts.forEach {
                addCandidate(show: $0.show, season: $0.season, number: $0.number)
            }
            streams.forEach {
                addCandidate(show: $0.embedded.show, season: $0.season, number: $0.number)
            }
        }

        let ranked = candidates.values.sorted { left, right in
            let leftWeight = left.show.weight ?? 0
            let rightWeight = right.show.weight ?? 0
            if leftWeight != rightWeight { return leftWeight > rightWeight }
            return left.show.name < right.show.name
        }
        return TVMazeDiscovery(
            airingSoon: ranked.prefix(40).map { makeShow($0.show) },
            premieres: ranked.filter(\.isPremiere).prefix(20).map { makeShow($0.show) }
        )
    }

    func episodes(
        for show: Show,
        includingHistory: Bool = false,
        timeZone: TimeZone = .current
    ) async throws -> [Airing] {
        guard let tvmazeID = show.tvmazeID,
              let url = URL(string: "https://api.tvmaze.com/shows/\(tvmazeID)/episodes") else {
            return []
        }

        let data = try await request(url)
        let episodes = try decoder.decode([EpisodeDTO].self, from: data)
        let mapped = episodes.map { item in
            let date = airDate(for: item, timeZone: timeZone)
            return Airing(
                id: episodeIDOffset + item.id,
                showID: show.id,
                season: item.season ?? 0,
                episode: item.number ?? 0,
                title: item.name,
                airDate: date,
                runtime: item.runtime ?? 0,
                service: show.network
            )
        }
        .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfLastWeek = calendar.date(
            byAdding: .day,
            value: -7,
            to: startOfToday
        )!
        let requestedEpisodes = includingHistory ? mapped : mapped.filter { airing in
            guard let date = airing.airDate else { return true }
            return date >= startOfLastWeek
        }
        let hasUpcoming = requestedEpisodes.contains { airing in
            guard let date = airing.airDate else { return true }
            return date >= startOfToday
        }

        if !hasUpcoming && show.status.lowercased() != "ended" {
            return [Airing(
                id: episodeIDOffset - tvmazeID,
                showID: show.id,
                season: 0,
                episode: 0,
                title: "Next episode",
                airDate: nil,
                runtime: 0,
                service: show.network
            )] + requestedEpisodes
        }

        return requestedEpisodes
    }

    private func request(_ url: URL, canRetry: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
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

    private func airDate(for episode: EpisodeDTO, timeZone: TimeZone) -> Date? {
        if let stamp = episode.airstamp {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: stamp) { return date }
        }
        guard let value = episode.airdate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
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

private struct DiscoveryCandidate {
    let show: ShowDTO
    let isPremiere: Bool
}

private struct ScheduleEpisodeDTO: Decodable {
    let season: Int?
    let number: Int?
    let show: ShowDTO
}

private struct WebScheduleEpisodeDTO: Decodable {
    let season: Int?
    let number: Int?
    let embedded: EmbeddedShowDTO

    private enum CodingKeys: String, CodingKey {
        case season, number
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
