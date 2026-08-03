import Foundation

struct AniListClient {
    enum APIError: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "AniList could not complete the request." }
    }

    private let decoder = JSONDecoder()
    private let showIDOffset = 4_000_000_000
    private let episodeIDOffset = 8_000_000_000
    private let tints = ["D7A84A", "79A8D8", "DA7C82", "70B79A", "AE8BD4", "D48AAE"]

    func searchAnime(query: String) async throws -> [Show] {
        let queryDocument = """
        query ($search: String) {
          Page(page: 1, perPage: 12) {
            media(search: $search, type: ANIME, isAdult: false) {
              id
              title { english romaji native }
              coverImage { extraLarge }
              genres
              status
              format
              duration
              countryOfOrigin
              studios(isMain: true) { nodes { name } }
              startDate { year month day }
              description(asHtml: false)
            }
          }
        }
        """
        let payload: SearchPayload = try await request(query: queryDocument, variables: ["search": query])
        return payload.data.page.media.map { item in
            let title = item.title.english ?? item.title.romaji ?? item.title.native ?? "Untitled"
            let isMovie = item.format == "MOVIE"
            return Show(
                id: showIDOffset + item.id,
                tvmazeID: nil,
                anilistID: item.id,
                title: title,
                network: item.studios.nodes.first?.name ?? regionName(item.countryOfOrigin) ?? "AniList",
                genres: ["Anime"] + item.genres,
                imageName: nil,
                imageURL: item.coverImage.extraLarge.flatMap(URL.init(string:)),
                tintHex: tints[item.id % tints.count],
                summary: cleanSummary(item.description),
                status: item.status.replacingOccurrences(of: "_", with: " ").capitalized,
                mediaType: isMovie ? .movie : .tvShow,
                releaseDate: isMovie ? item.startDate.date : nil,
                runtime: item.duration ?? 0
            )
        }
    }

    func episodes(
        for show: Show,
        includingHistory: Bool = false,
        timeZone: TimeZone = .current
    ) async throws -> [Airing] {
        guard let anilistID = show.anilistID, show.mediaType == .tvShow else { return [] }
        let queryDocument = """
        query ($id: Int) {
          Media(id: $id, type: ANIME) {
            status
            duration
            nextAiringEpisode { id airingAt episode }
            airingSchedule(page: 1, perPage: 50) { nodes { id airingAt episode } }
          }
        }
        """
        let payload: SchedulePayload = try await request(query: queryDocument, variables: ["id": anilistID])
        let media = payload.data.media
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        var nodes = media.airingSchedule.nodes
        if let next = media.nextAiringEpisode, !nodes.contains(where: { $0.id == next.id }) {
            nodes.append(next)
        }
        let mapped = nodes.map { node in
            Airing(
                id: episodeIDOffset + node.id,
                showID: show.id,
                season: 1,
                episode: node.episode,
                title: "Episode \(node.episode)",
                airDate: Date(timeIntervalSince1970: TimeInterval(node.airingAt)),
                runtime: media.duration ?? show.runtime,
                service: show.network
            )
        }
        .filter { includingHistory || ($0.airDate ?? .distantPast) >= startOfLastWeek }
        .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }

        if mapped.contains(where: { ($0.airDate ?? .distantPast) >= startOfToday }) {
            return mapped
        }
        if media.status == "RELEASING" || media.status == "NOT_YET_RELEASED" {
            return [Airing(
                id: episodeIDOffset - anilistID,
                showID: show.id,
                season: 0,
                episode: 0,
                title: "Next episode",
                airDate: nil,
                runtime: media.duration ?? show.runtime,
                service: show.network
            )] + mapped
        }
        return mapped
    }

    private func request<Response: Decodable>(query: String, variables: [String: Any]) async throws -> Response {
        guard let url = URL(string: "https://graphql.anilist.co") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.invalidResponse
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func regionName(_ code: String?) -> String? {
        guard let code else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    private func cleanSummary(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "No summary available." }
        return value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

private struct SearchPayload: Decodable { let data: SearchData }
private struct SearchData: Decodable { let page: AniListPage; private enum CodingKeys: String, CodingKey { case page = "Page" } }
private struct AniListPage: Decodable { let media: [AniListMedia] }

private struct AniListMedia: Decodable {
    let id: Int
    let title: AniListTitle
    let coverImage: AniListCover
    let genres: [String]
    let status: String
    let format: String?
    let duration: Int?
    let countryOfOrigin: String?
    let studios: AniListStudios
    let startDate: AniListDate
    let description: String?
}

private struct AniListTitle: Decodable { let english: String?; let romaji: String?; let native: String? }
private struct AniListCover: Decodable { let extraLarge: String? }
private struct AniListStudios: Decodable { let nodes: [AniListStudio] }
private struct AniListStudio: Decodable { let name: String }
private struct AniListDate: Decodable {
    let year: Int?
    let month: Int?
    let day: Int?
    var date: Date? {
        guard let year, let month, let day else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }
}

private struct SchedulePayload: Decodable { let data: ScheduleData }
private struct ScheduleData: Decodable { let media: AniListScheduleMedia; private enum CodingKeys: String, CodingKey { case media = "Media" } }
private struct AniListScheduleMedia: Decodable {
    let status: String
    let duration: Int?
    let nextAiringEpisode: AniListAiring?
    let airingSchedule: AniListAiringNodes
}
private struct AniListAiringNodes: Decodable { let nodes: [AniListAiring] }
private struct AniListAiring: Decodable { let id: Int; let airingAt: Int; let episode: Int }
