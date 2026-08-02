import Foundation
import AVFoundation

struct AppleMovieClient {
    private let decoder = JSONDecoder()
    private let movieIDOffset = 2_000_000_000
    private let tints = ["D4A45B", "E06C5F", "67A6C8", "B68BD4", "6EAD7C", "D783A5"]

    func searchMovies(query: String) async throws -> [Show] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "limit", value: "30")
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return [] }
        let payload = try decoder.decode(MovieSearchResponse.self, from: data)

        return payload.results
            .filter { $0.kind == "feature-movie" }
            .compactMap { item -> Show? in
                guard let trackID = item.trackID, let trackName = item.trackName else { return nil }
                return Show(
                    id: movieIDOffset + trackID,
                    tvmazeID: nil,
                    title: trackName,
                    network: "Apple TV Store",
                    genres: [item.primaryGenreName].compactMap { $0 },
                    imageName: nil,
                    imageURL: artworkURL(from: item.artworkURL),
                    tintHex: tints[trackID % tints.count],
                    summary: item.longDescription ?? item.shortDescription ?? "No summary available.",
                    status: "Released",
                    mediaType: .movie,
                    releaseDate: parseDate(item.releaseDate),
                    runtime: (item.trackTimeMillis ?? 0) / 60_000
                )
            }
            .prefix(6)
            .map { $0 }
    }

    private func artworkURL(from value: String?) -> URL? {
        guard let value else { return nil }
        return URL(string: value.replacingOccurrences(of: "100x100bb", with: "600x900bb"))
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct MovieSearchResponse: Decodable {
    let results: [MovieDTO]
}

private struct MovieDTO: Decodable {
    let kind: String?
    let trackID: Int?
    let trackName: String?
    let artworkURL: String?
    let releaseDate: String?
    let trackTimeMillis: Int?
    let primaryGenreName: String?
    let longDescription: String?
    let shortDescription: String?

    private enum CodingKeys: String, CodingKey {
        case kind, trackName, releaseDate, trackTimeMillis, primaryGenreName, longDescription, shortDescription
        case trackID = "trackId"
        case artworkURL = "artworkUrl100"
    }
}

struct ThemeSong: Identifiable {
    let id: Int
    let title: String
    let artist: String
    let collection: String
    let previewURL: URL
    let artworkURL: URL?
}

final class ThemeSongClient {
    private let decoder = JSONDecoder()
    private let wrestlingThemes = [
        WrestlingEntranceTheme(wrestler: "Randy Orton", track: "Voices", artist: "Rev Theory"),
        WrestlingEntranceTheme(wrestler: "CM Punk", track: "Cult of Personality", artist: "Living Colour"),
        WrestlingEntranceTheme(wrestler: "Cody Rhodes", track: "Kingdom", artist: "Downstait"),
        WrestlingEntranceTheme(wrestler: "John Cena", track: "The Time Is Now", artist: "John Cena"),
        WrestlingEntranceTheme(wrestler: "Roman Reigns", track: "Head of the Table", artist: "def rebel"),
        WrestlingEntranceTheme(wrestler: "Seth Rollins", track: "The Vision", artist: "def rebel"),
        WrestlingEntranceTheme(wrestler: "Kenny Omega", track: "Battle Cry (Kenny Omega Theme)", artist: "All Elite Wrestling"),
        WrestlingEntranceTheme(wrestler: "Will Ospreay", track: "Elevated", artist: "It Lives, It Breathes"),
        WrestlingEntranceTheme(wrestler: "Edge", track: "Metalingus", artist: "Alter Bridge"),
        WrestlingEntranceTheme(wrestler: "Chris Jericho", track: "Judas", artist: "Fozzy"),
        WrestlingEntranceTheme(wrestler: "AJ Styles", track: "Phenomenal", artist: "CFO$"),
        WrestlingEntranceTheme(wrestler: "Shinsuke Nakamura", track: "The Rising Sun", artist: "CFO$"),
        WrestlingEntranceTheme(wrestler: "Finn Balor", track: "Catch Your Breath", artist: "CFO$"),
        WrestlingEntranceTheme(wrestler: "Rhea Ripley", track: "Demon In Your Dreams", artist: "def rebel"),
        WrestlingEntranceTheme(wrestler: "Becky Lynch", track: "Celtic Invasion", artist: "CFO$"),
        WrestlingEntranceTheme(wrestler: "Triple H", track: "The Game", artist: "Motörhead"),
        WrestlingEntranceTheme(wrestler: "Batista", track: "I Walk Alone", artist: "Saliva"),
        WrestlingEntranceTheme(wrestler: "Rey Mysterio", track: "Booyaka 619", artist: "P.O.D."),
        WrestlingEntranceTheme(wrestler: "Jeff Hardy", track: "No More Words", artist: "Endeverafter"),
        WrestlingEntranceTheme(wrestler: "Sami Zayn", track: "Worlds Apart", artist: "CFO$"),
        WrestlingEntranceTheme(wrestler: "Kevin Owens", track: "Fight", artist: "CFO$"),
        WrestlingEntranceTheme(wrestler: "Drew McIntyre", track: "Broken Dreams", artist: "Jim Johnston"),
        WrestlingEntranceTheme(wrestler: "The Undertaker", track: "Rest In Peace", artist: "Jim Johnston"),
        WrestlingEntranceTheme(wrestler: "Stone Cold Steve Austin", track: "I Won't Do What You Tell Me", artist: "Jim Johnston"),
        WrestlingEntranceTheme(wrestler: "Lita", track: "LoveFuryPassionEnergy", artist: "Boy Hits Car"),
        WrestlingEntranceTheme(wrestler: "IYO SKY", track: "Tokyo Shock", artist: "def rebel"),
        WrestlingEntranceTheme(wrestler: "Bayley", track: "Deliverance", artist: "def rebel"),
        WrestlingEntranceTheme(wrestler: "MJF", track: "Mjf - Dig Deep", artist: "All Elite Wrestling"),
        WrestlingEntranceTheme(wrestler: "Kane", track: "Slow Chemical", artist: "Finger Eleven"),
        WrestlingEntranceTheme(wrestler: "CM Punk", track: "This Fire Burns", artist: "Killswitch Engage")
    ]
    private var wrestlingShuffleBag: [WrestlingEntranceTheme] = []

    func theme(for show: Show) async throws -> ThemeSong {
        if show.title.localizedCaseInsensitiveContains("WWE") {
            return try await nextWrestlingEntranceTheme()
        }

        let results = try await songs(matching: "\(show.title) main title theme original series soundtrack")
        let showTitle = show.title.lowercased()
        let match = results
            .filter {
                $0.previewURL != nil
                    && isLikelyTheme($0, for: showTitle)
                    && !isUnrelatedSeasonalTrack($0, for: showTitle)
            }
            .max { score($0, for: showTitle) < score($1, for: showTitle) }

        guard let match,
              score(match, for: showTitle) >= 100 else { throw ThemeError.notFound }
        return try makeThemeSong(from: match, fallbackCollection: show.title)
    }

    private func nextWrestlingEntranceTheme() async throws -> ThemeSong {
        if wrestlingShuffleBag.isEmpty { wrestlingShuffleBag = wrestlingThemes.shuffled() }
        let attempts = wrestlingShuffleBag.count

        for _ in 0..<attempts {
            let theme = wrestlingShuffleBag.removeFirst()
            let results = try await songs(matching: "\(theme.track) \(theme.artist)")
            guard let match = results.first(where: { song in
                song.previewURL != nil
                    && song.trackName.localizedCaseInsensitiveContains(theme.track)
                    && song.artistName.localizedCaseInsensitiveContains(theme.artist)
            }) else { continue }

            return try makeThemeSong(
                from: match,
                fallbackCollection: "\(theme.wrestler) · Pro Wrestling"
            )
        }

        throw ThemeError.notFound
    }

    private func songs(matching term: String) async throws -> [SongDTO] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "limit", value: "20")
        ]
        guard let url = components?.url else { throw ThemeError.notFound }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ThemeError.notFound
        }
        return try decoder.decode(SongSearchResponse.self, from: data).results
    }

    private func makeThemeSong(from match: SongDTO, fallbackCollection: String) throws -> ThemeSong {
        guard let previewURL = match.previewURL else { throw ThemeError.notFound }
        return ThemeSong(
            id: match.trackID,
            title: match.trackName,
            artist: match.artistName,
            collection: match.collectionName ?? fallbackCollection,
            previewURL: previewURL,
            artworkURL: match.artworkURL.flatMap {
                URL(string: $0.absoluteString.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
            }
        )
    }

    private func score(_ song: SongDTO, for showTitle: String) -> Int {
        let track = song.trackName.lowercased()
        let collection = song.collectionName?.lowercased() ?? ""
        var value = collection.contains(showTitle) ? 100 : 0
        if track == "main title" || track == "main titles" { value += 220 }
        else if track.contains("main title") || track.contains("main titles") { value += 80 }
        if track.contains("theme") { value += 50 }
        if collection.contains("original series soundtrack") { value += 100 }
        else if collection.contains("soundtrack") || collection.contains("original series") { value += 30 }
        if track.contains("cover") || track.contains("version") || track.contains("remix") { value -= 120 }
        return value
    }

    private func isLikelyTheme(_ song: SongDTO, for showTitle: String) -> Bool {
        let track = song.trackName.lowercased()
        let themeTerms = ["main title", "theme", "opening", "intro", "title sequence"]
        return themeTerms.contains(where: track.contains)
            || track == showTitle
            || track.contains(showTitle)
    }

    private func isUnrelatedSeasonalTrack(_ song: SongDTO, for showTitle: String) -> Bool {
        let seasonalTerms = ["holiday", "christmas", "xmas", "carol", "mistletoe", "santa"]
        guard !seasonalTerms.contains(where: showTitle.contains) else { return false }

        let track = song.trackName.lowercased()
        let collection = song.collectionName?.lowercased() ?? ""
        return seasonalTerms.contains { track.contains($0) || collection.contains($0) }
    }

    enum ThemeError: LocalizedError {
        case notFound

        var errorDescription: String? { "No theme preview was found for this title." }
    }
}

private struct WrestlingEntranceTheme {
    let wrestler: String
    let track: String
    let artist: String
}

@MainActor
final class ThemeSongPlayer: ObservableObject {
    @Published private(set) var currentSong: ThemeSong?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client = ThemeSongClient()
    private var player: AVPlayer?
    private var playbackEndObserver: NSObjectProtocol?
    private var hasAttemptedAutoplay = false
    private var subscribedShows: [Show] = []
    private var shuffleBag: [Show] = []
    private var currentShowID: Int?
    private var playbackHistory: [PlaybackEntry] = []
    private var playbackForward: [PlaybackEntry] = []

    func autoplay(from shows: [Show]) async {
        guard !hasAttemptedAutoplay, !shows.isEmpty else { return }
        hasAttemptedAutoplay = true
        subscribedShows = shows
        refillShuffleBag()
        await playNextTheme()
    }

    func updateSubscriptions(_ shows: [Show]) async {
        subscribedShows = shows
        shuffleBag = []

        guard !shows.isEmpty else {
            disable()
            return
        }

        if let currentShowID, !shows.contains(where: { $0.id == currentShowID }) {
            player?.pause()
            currentSong = nil
            isPlaying = false
            self.currentShowID = nil
            refillShuffleBag()
            await playNextTheme()
        }
    }

    func skipToNextTheme() async {
        player?.pause()
        await advanceToNextTheme()
    }

    func playPreviousTheme() {
        guard let previous = playbackHistory.popLast() else { return }
        player?.pause()
        if let currentEntry {
            playbackForward.append(currentEntry)
        }
        start(previous, recordCurrent: false, clearForward: false)
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func playNextTheme(allowFreshCycle: Bool = true) async {
        guard !subscribedShows.isEmpty else { return }
        if shuffleBag.isEmpty { refillShuffleBag() }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let candidates = shuffleBag
        shuffleBag = []

        for (index, show) in candidates.enumerated() {
            do {
                let song = try await client.theme(for: show)
                if index + 1 < candidates.count {
                    shuffleBag = Array(candidates[(index + 1)...])
                }
                start(song, for: show)
                return
            } catch {
                continue
            }
        }

        if allowFreshCycle, candidates.count < subscribedShows.count {
            refillShuffleBag()
            await playNextTheme(allowFreshCycle: false)
            return
        }

        errorMessage = "No theme preview was found for your subscriptions."
        isPlaying = false
    }

    private func advanceToNextTheme() async {
        if let next = playbackForward.popLast() {
            start(next, recordCurrent: true, clearForward: false)
        } else {
            await playNextTheme()
        }
    }

    func disable() {
        player?.pause()
        player = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        currentSong = nil
        currentShowID = nil
        isPlaying = false
        errorMessage = nil
        hasAttemptedAutoplay = false
        subscribedShows = []
        shuffleBag = []
        playbackHistory = []
        playbackForward = []
    }

    private func refillShuffleBag() {
        shuffleBag = subscribedShows.shuffled()
        guard shuffleBag.count > 1,
              shuffleBag.first?.id == currentShowID else { return }
        shuffleBag.swapAt(0, Int.random(in: 1..<shuffleBag.count))
    }

    private var currentEntry: PlaybackEntry? {
        guard let currentSong, let currentShowID else { return nil }
        return PlaybackEntry(song: currentSong, showID: currentShowID)
    }

    private func start(_ song: ThemeSong, for show: Show) {
        start(PlaybackEntry(song: song, showID: show.id))
    }

    private func start(
        _ entry: PlaybackEntry,
        recordCurrent: Bool = true,
        clearForward: Bool = true
    ) {
        if recordCurrent, let currentEntry {
            playbackHistory.append(currentEntry)
        }
        if clearForward {
            playbackForward = []
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: entry.song.previewURL)
        let nextPlayer = AVPlayer(playerItem: item)

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.advanceToNextTheme()
            }
        }

        player = nextPlayer
        currentSong = entry.song
        currentShowID = entry.showID
        nextPlayer.volume = 0.15
        nextPlayer.play()
        isPlaying = true
    }
}

private struct PlaybackEntry {
    let song: ThemeSong
    let showID: Int
}

private struct SongSearchResponse: Decodable {
    let results: [SongDTO]
}

private struct SongDTO: Decodable {
    let trackID: Int
    let trackName: String
    let artistName: String
    let collectionName: String?
    let previewURL: URL?
    let artworkURL: URL?

    private enum CodingKeys: String, CodingKey {
        case trackName, artistName, collectionName
        case trackID = "trackId"
        case previewURL = "previewUrl"
        case artworkURL = "artworkUrl100"
    }
}
