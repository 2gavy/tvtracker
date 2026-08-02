import Foundation

@MainActor
final class ShowStore: ObservableObject {
    @Published private(set) var followedIDs: Set<Int>
    @Published private(set) var watchedAiringIDs: Set<Int>
    @Published private(set) var loadingScheduleIDs: Set<Int> = []
    @Published private(set) var isRefreshingSchedules = false
    @Published private(set) var hasLoadedHistory = false

    @Published private(set) var shows: [Show]
    @Published private(set) var airings: [Airing]

    private let followedKey = "followedShowIDs"
    private let watchedKey = "watchedAiringIDs"
    private let savedShowsKey = "savedTVMazeShows"
    private let savedAiringsKey = "savedTVMazeAirings"
    private let client = TVMazeClient()
    private let tmdbClient = TMDBClient()
    private let aniListClient = AniListClient()

    init() {
        let savedShows: [Show] = Self.load([Show].self, key: savedShowsKey) ?? []
        let savedAirings: [Airing] = Self.load([Airing].self, key: savedAiringsKey) ?? []
        shows = DemoData.shows + savedShows.filter { saved in
            !DemoData.shows.contains { $0.id == saved.id }
        }
        let restoredShowIDs = Set(savedAirings.map(\.showID))
        airings = DemoData.airings.filter { !restoredShowIDs.contains($0.showID) } + savedAirings

        if let saved = UserDefaults.standard.array(forKey: followedKey) as? [Int] {
            followedIDs = Set(saved)
        } else {
            followedIDs = [101, 102, 104, 106]
        }

        watchedAiringIDs = Set(UserDefaults.standard.array(forKey: watchedKey) as? [Int] ?? [])

        Task { [weak self] in
            await self?.refreshFollowedSchedules()
        }
    }

    var followedShows: [Show] {
        shows.filter { followedIDs.contains($0.id) }
    }

    var followedAirings: [Airing] {
        airings.filter { followedIDs.contains($0.showID) }
    }

    var watchedAirings: [Airing] {
        airings
            .filter { watchedAiringIDs.contains($0.id) }
            .sorted { ($0.airDate ?? .distantPast) > ($1.airDate ?? .distantPast) }
    }

    var watchedMinutes: Int {
        watchedAirings.reduce(0) { $0 + $1.runtime }
    }

    var watchedDuration: String {
        let hours = watchedMinutes / 60
        let minutes = watchedMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    func show(for id: Int) -> Show {
        shows.first { $0.id == id } ?? shows[0]
    }

    func isFollowing(_ show: Show) -> Bool {
        followedIDs.contains(show.id)
    }

    func toggleFollow(_ show: Show) {
        if followedIDs.contains(show.id) {
            followedIDs.remove(show.id)
        } else {
            if !shows.contains(where: { $0.id == show.id }) {
                shows.append(show)
                persistRemoteShows()
            }
            followedIDs.insert(show.id)
            if show.mediaType == .movie {
                addMovieRelease(for: show)
            } else if show.tvmazeID != nil || show.tmdbID != nil || show.anilistID != nil {
                Task { await refreshSchedule(for: show) }
            }
        }
        UserDefaults.standard.set(Array(followedIDs), forKey: followedKey)
    }

    func isLoadingSchedule(for show: Show) -> Bool {
        loadingScheduleIDs.contains(show.id)
    }

    func refreshSchedule(for show: Show, includingHistory: Bool = false) async {
        guard show.mediaType == .tvShow,
              show.tvmazeID != nil || show.tmdbID != nil || show.anilistID != nil,
              !loadingScheduleIDs.contains(show.id) else { return }
        loadingScheduleIDs.insert(show.id)
        defer { loadingScheduleIDs.remove(show.id) }

        do {
            let episodes: [Airing]
            if show.tvmazeID != nil {
                episodes = try await client.episodes(for: show, includingHistory: includingHistory)
            } else if show.tmdbID != nil {
                episodes = try await tmdbClient.episodes(for: show, includingHistory: includingHistory)
            } else {
                episodes = try await aniListClient.episodes(for: show, includingHistory: includingHistory)
            }
            let startOfToday = Calendar.current.startOfDay(for: .now)
            let startOfLastWeek = Calendar.current.date(
                byAdding: .day,
                value: -7,
                to: startOfToday
            )!
            airings.removeAll { airing in
                guard airing.showID == show.id else { return false }
                if includingHistory { return true }
                guard let date = airing.airDate else { return true }
                return date >= startOfLastWeek
            }
            airings.append(contentsOf: episodes)
            persistRemoteAirings()
        } catch {
            // The subscription remains saved; a later refresh can retry the schedule.
        }
    }

    func refreshFollowedSchedules() async {
        guard !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }

        for show in followedShows where show.mediaType == .tvShow
            && (show.tvmazeID != nil || show.tmdbID != nil || show.anilistID != nil) {
            await refreshSchedule(for: show)
        }
    }

    func loadPreviousSeasons() async {
        guard !hasLoadedHistory, !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer {
            hasLoadedHistory = true
            isRefreshingSchedules = false
        }

        for show in followedShows where show.mediaType == .tvShow
            && (show.tvmazeID != nil || show.tmdbID != nil || show.anilistID != nil) {
            await refreshSchedule(for: show, includingHistory: true)
        }
    }

    func isWatched(_ airing: Airing) -> Bool {
        watchedAiringIDs.contains(airing.id)
    }

    func toggleWatched(_ airing: Airing) {
        if watchedAiringIDs.contains(airing.id) {
            watchedAiringIDs.remove(airing.id)
        } else {
            watchedAiringIDs.insert(airing.id)
        }
        UserDefaults.standard.set(Array(watchedAiringIDs), forKey: watchedKey)
    }

    func sections(matching filter: MediaFilter = .all) -> [AiringSection] {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let startOfLastWeek = Calendar.current.date(
            byAdding: .day,
            value: -7,
            to: startOfToday
        )!
        let source = followedAirings.filter { airing in
            guard filter.includes(show(for: airing.showID)) else { return false }
            if hasLoadedHistory { return true }
            guard let date = airing.airDate else { return true }
            return date >= startOfLastWeek
        }
        let sorted = source.sorted { lhs, rhs in
            switch (lhs.airDate, rhs.airDate) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return show(for: lhs.showID).title < show(for: rhs.showID).title
            }
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sorted) { airing -> String in
            guard let date = airing.airDate else { return "Date TBA" }
            if date >= startOfLastWeek, date < startOfToday { return "Last week" }
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInTomorrow(date) { return "Tomorrow" }
            if date >= startOfToday,
               date < calendar.date(byAdding: .day, value: 7, to: startOfToday)! {
                return "This week"
            }
            return date.formatted(.dateTime.month(.wide).year())
        }

        return grouped.map { key, value in
            AiringSection(
                title: key,
                subtitle: key == "Date TBA" ? "Renewed, but no premiere date yet" : nil,
                airings: value
            )
        }
        .sorted { left, right in
            let leftDate = left.airings.compactMap(\.airDate).min()
            let rightDate = right.airings.compactMap(\.airDate).min()
            switch (leftDate, rightDate) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.title < right.title
            }
        }
    }

    private func persistRemoteShows() {
        let demoIDs = Set(DemoData.shows.map(\.id))
        let remote = shows.filter { !demoIDs.contains($0.id) }
        Self.save(remote, key: savedShowsKey)
    }

    private func addMovieRelease(for show: Show) {
        guard !airings.contains(where: { $0.showID == show.id }) else { return }
        airings.append(Airing(
            id: 6_000_000_000 + show.id,
            showID: show.id,
            season: 0,
            episode: 0,
            title: "Movie release",
            airDate: show.releaseDate,
            runtime: show.runtime,
            service: show.network
        ))
        persistRemoteAirings()
    }

    private func persistRemoteAirings() {
        Self.save(airings.filter { $0.id > 1_000_000_000 }, key: savedAiringsKey)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private enum DemoData {
    private static func releaseDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 20))
    }

    static let shows: [Show] = [
        Show(id: 101, tvmazeID: 44933, title: "Severance", network: "Apple TV+", genres: ["Drama", "Mystery"], imageName: "PosterSeverance", imageURL: nil, tintHex: "F4CF3B", summary: "Mark leads a team whose work memories have been surgically divided from their personal lives.", status: "Running"),
        Show(id: 102, tvmazeID: 54198, title: "The Bear", network: "FX / Hulu", genres: ["Drama", "Comedy"], imageName: "PosterTheBear", imageURL: nil, tintHex: "55A7D9", summary: "A young chef returns home to run his family's sandwich shop.", status: "Ended"),
        Show(id: 103, tvmazeID: 51394, title: "The White Lotus", network: "HBO", genres: ["Drama", "Comedy"], imageName: "PosterWhiteLotus", imageURL: nil, tintHex: "E66B53", summary: "A week in the life of vacationers and employees at an exclusive resort.", status: "Running"),
        Show(id: 104, tvmazeID: 38052, title: "Silo", network: "Apple TV+", genres: ["Drama", "Science Fiction"], imageName: "PosterSilo", imageURL: nil, tintHex: "C69263", summary: "Thousands live underground, unaware of why the silo was built.", status: "Running"),
        Show(id: 105, tvmazeID: 52341, title: "Andor", network: "Disney+", genres: ["Drama", "Science Fiction"], imageName: "PosterAndor", imageURL: nil, tintHex: "E86C3D", summary: "The story of a rebellion taking shape against an empire.", status: "Ended"),
        Show(id: 106, tvmazeID: 45039, title: "Slow Horses", network: "Apple TV+", genres: ["Drama", "Thriller"], imageName: "PosterSlowHorses", imageURL: nil, tintHex: "76A06A", summary: "A dysfunctional team of MI5 agents navigates the espionage world's smoke and mirrors.", status: "Running"),
        Show(id: 107, tvmazeID: 35951, title: "Foundation", network: "Apple TV+", genres: ["Drama", "Science Fiction"], imageName: "PosterFoundation", imageURL: nil, tintHex: "B88DE1", summary: "Exiles work to rebuild civilization amid the fall of a galactic empire.", status: "Running"),
        Show(id: 108, tvmazeID: 54914, title: "Hacks", network: "Max", genres: ["Comedy"], imageName: "PosterHacks", imageURL: nil, tintHex: "ED6D9E", summary: "A legendary comedian forms a dark mentorship with a young comedy writer.", status: "Ended"),
        Show(id: 109, tvmazeID: nil, title: "Dune: Part Two", network: "Warner Bros.", genres: ["Science Fiction", "Adventure"], imageName: nil, imageURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Video221/v4/71/a8/31/71a8312e-a20a-29b2-af70-5cab08908657/aca7621e-74e7-419a-96cd-5aaff99fb0cc_DUNE_PART2_V_DD_KA_TT_2000x3000_300dpi_EN-srgb.lsr/600x900bb.jpg"), tintHex: "D4A45B", summary: "Paul Atreides unites with Chani and the Fremen while seeking revenge against the conspirators who destroyed his family.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2024, 3, 1), runtime: 166),
        Show(id: 110, tvmazeID: nil, title: "Spider-Man: Across the Spider-Verse", network: "Sony Pictures", genres: ["Animation", "Adventure"], imageName: nil, imageURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Video221/v4/5e/88/10/5e8810c1-9025-b950-8dae-cfdcb7dbd75f/DP_10232262_SPIDER-MANACROSSTHESPIDER-VERSE_2000x3000_PURPLEHUEKeyArt.jpg/600x900bb.jpg"), tintHex: "E06C5F", summary: "Miles Morales is catapulted across the Multiverse and meets a team of Spider-People charged with protecting it.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2023, 6, 2), runtime: 141),
        Show(id: 111, tvmazeID: nil, title: "The Batman", network: "Warner Bros.", genres: ["Action", "Crime"], imageName: nil, imageURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Video116/v4/f6/7f/d8/f67fd824-b916-253c-61e7-5cbc659b8412/pr_source.lsr/600x900bb.jpg"), tintHex: "B94742", summary: "Batman ventures into Gotham City's underworld when a sadistic killer leaves behind a trail of cryptic clues.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2022, 3, 4), runtime: 176),
        Show(id: 112, tvmazeID: 69956, title: "Frieren: Beyond Journey's End", network: "NTV", genres: ["Anime", "Adventure", "Fantasy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/479/1198409.jpg"), tintHex: "A9B8E8", summary: "An elven mage retraces the journey she once shared with her companions and learns what their brief lives meant.", status: "To Be Determined"),
        Show(id: 113, tvmazeID: 64632, title: "Solo Leveling", network: "Tokyo MX", genres: ["Anime", "Action", "Fantasy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/497/1244908.jpg"), tintHex: "6D8CD8", summary: "Humanity's weakest hunter gains a mysterious ability that lets him level up without limit.", status: "Running"),
        Show(id: 114, tvmazeID: 48450, title: "Jujutsu Kaisen", network: "MBS", genres: ["Anime", "Action", "Supernatural"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/608/1521905.jpg"), tintHex: "D56C7C", summary: "A student joins a secret organization of sorcerers after becoming host to a powerful curse.", status: "Running"),
        Show(id: 115, tvmazeID: nil, tmdbID: 1_671_548, title: "Dear You", network: "China", genres: ["Drama", "Family"], imageName: nil, imageURL: URL(string: "https://image.tmdb.org/t/p/w500/rjmhzdVS3Ia535pFawju857e2Na.jpg"), tintHex: "D9AF52", summary: "A grandson travels to Thailand to uncover a family story and find the grandfather he never knew.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2026, 6, 18), runtime: 118)
    ]

    static let airings: [Airing] = {
        let calendar = Calendar.current
        func date(_ days: Int, hour: Int = 20) -> Date {
            let start = calendar.startOfDay(for: .now)
            return calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: days, to: start)!)!
        }

        return [
            Airing(id: 1, showID: 106, season: 6, episode: 2, title: "A Proper Mess", airDate: date(0, hour: 21), runtime: 48, service: "Apple TV+"),
            Airing(id: 2, showID: 102, season: 5, episode: 4, title: "The Review", airDate: date(1, hour: 20), runtime: 32, service: "Hulu"),
            Airing(id: 3, showID: 103, season: 4, episode: 1, title: "Arrivals", airDate: date(3, hour: 21), runtime: 61, service: "Max"),
            Airing(id: 4, showID: 108, season: 5, episode: 7, title: "The Set", airDate: date(5, hour: 22), runtime: 28, service: "Max"),
            Airing(id: 5, showID: 107, season: 4, episode: 1, title: "The Mule", airDate: date(12, hour: 20), runtime: 54, service: "Apple TV+"),
            Airing(id: 6, showID: 105, season: 3, episode: 1, title: "Episode 1", airDate: date(29, hour: 20), runtime: 51, service: "Disney+"),
            Airing(id: 7, showID: 104, season: 3, episode: 1, title: "The Door", airDate: date(43, hour: 20), runtime: 52, service: "Apple TV+"),
            Airing(id: 8, showID: 101, season: 3, episode: 1, title: "Season premiere", airDate: nil, runtime: 0, service: "Apple TV+")
        ]
    }()
}
