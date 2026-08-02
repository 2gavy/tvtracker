import Foundation

enum MediaType: String, Codable, CaseIterable, Identifiable {
    case tvShow
    case movie

    var id: String { rawValue }
    var title: String { self == .tvShow ? "TV Shows" : "Movies" }
    var systemImage: String { self == .tvShow ? "tv" : "film" }
}

struct Show: Identifiable, Hashable, Codable {
    let id: Int
    let tvmazeID: Int?
    let tmdbID: Int?
    let anilistID: Int?
    let title: String
    let network: String
    let genres: [String]
    let imageName: String?
    let imageURL: URL?
    let tintHex: String
    let summary: String
    let status: String
    let mediaType: MediaType
    let releaseDate: Date?
    let runtime: Int

    init(
        id: Int,
        tvmazeID: Int?,
        tmdbID: Int? = nil,
        anilistID: Int? = nil,
        title: String,
        network: String,
        genres: [String],
        imageName: String?,
        imageURL: URL?,
        tintHex: String,
        summary: String,
        status: String,
        mediaType: MediaType = .tvShow,
        releaseDate: Date? = nil,
        runtime: Int = 0
    ) {
        self.id = id
        self.tvmazeID = tvmazeID
        self.tmdbID = tmdbID
        self.anilistID = anilistID
        self.title = title
        self.network = network
        self.genres = genres
        self.imageName = imageName
        self.imageURL = imageURL
        self.tintHex = tintHex
        self.summary = summary
        self.status = status
        self.mediaType = mediaType
        self.releaseDate = releaseDate
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case id, tvmazeID, tmdbID, anilistID, title, network, genres, imageName, imageURL, tintHex, summary, status, mediaType, releaseDate, runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        tvmazeID = try container.decodeIfPresent(Int.self, forKey: .tvmazeID)
        tmdbID = try container.decodeIfPresent(Int.self, forKey: .tmdbID)
        anilistID = try container.decodeIfPresent(Int.self, forKey: .anilistID)
        title = try container.decode(String.self, forKey: .title)
        network = try container.decode(String.self, forKey: .network)
        genres = try container.decode([String].self, forKey: .genres)
        imageName = try container.decodeIfPresent(String.self, forKey: .imageName)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        tintHex = try container.decode(String.self, forKey: .tintHex)
        summary = try container.decode(String.self, forKey: .summary)
        status = try container.decode(String.self, forKey: .status)
        mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .tvShow
        releaseDate = try container.decodeIfPresent(Date.self, forKey: .releaseDate)
        runtime = try container.decodeIfPresent(Int.self, forKey: .runtime) ?? 0
    }
}

struct Airing: Identifiable, Hashable, Codable {
    let id: Int
    let showID: Int
    let season: Int
    let episode: Int
    let title: String
    let airDate: Date?
    let runtime: Int
    let service: String

    var code: String {
        if season == 0 && episode == 0 { return "NEXT" }
        return "S\(season) E\(episode)"
    }
}

struct AiringSection: Identifiable {
    let title: String
    let subtitle: String?
    let airings: [Airing]

    var id: String { title }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case tvShows
    case movies
    case anime

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .tvShows: "TV Shows"
        case .movies: "Movies"
        case .anime: "Anime"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "rectangle.stack"
        case .tvShows: "tv"
        case .movies: "film"
        case .anime: "sparkles.tv"
        }
    }

    func includes(_ show: Show) -> Bool {
        switch self {
        case .all: true
        case .tvShows: show.mediaType == .tvShow
        case .movies: show.mediaType == .movie
        case .anime: show.genres.contains { $0.localizedCaseInsensitiveCompare("Anime") == .orderedSame }
        }
    }
}

enum AppTab: Hashable {
    case shows
    case discover
    case profile
}
