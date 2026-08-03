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
        return results.prefix(12).map { result in
            let item = result.show
            return Show(
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

    private func request(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.server(0) }
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
    let status: String
    let genres: [String]
    let network: ChannelDTO?
    let webChannel: ChannelDTO?
    let image: ImageDTO?
    let summary: String?
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
