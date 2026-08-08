import Foundation

@MainActor
final class ShowStore: ObservableObject {
    static let defaultTimeZoneIdentifier = "Asia/Singapore"

    @Published private(set) var followedIDs: Set<Int>
    @Published private(set) var watchedAiringIDs: Set<Int>
    @Published private(set) var loadingScheduleIDs: Set<Int> = []
    @Published private(set) var isRefreshingSchedules = false
    @Published private(set) var hasLoadedHistory = false

    @Published private(set) var shows: [Show]
    @Published private(set) var airings: [Airing]
    @Published var timeZoneIdentifier: String {
        didSet {
            guard TimeZone(identifier: timeZoneIdentifier) != nil else {
                timeZoneIdentifier = Self.defaultTimeZoneIdentifier
                return
            }
            UserDefaults.standard.set(timeZoneIdentifier, forKey: timeZoneKey)
            persistUserStateToCloud()
        }
    }

    private let followedKey = "followedShowIDs"
    private let watchedKey = "watchedAiringIDs"
    private let savedShowsKey = "savedTVMazeShows"
    private let savedAiringsKey = "savedTVMazeAirings"
    private let timeZoneKey = "scheduleTimeZoneIdentifier"
    private let cloudModifiedAtKey = "cloudStateModifiedAt"
    private let client = TVMazeClient()
    private let tmdbClient = TMDBClient()
    private let cloudStateStore = CloudStateStore()
    private var cloudObserver: NSObjectProtocol?
    private var isApplyingCloudState = false

    init() {
        let savedTimeZone = UserDefaults.standard.string(forKey: timeZoneKey)
        if let savedTimeZone, TimeZone(identifier: savedTimeZone) != nil {
            timeZoneIdentifier = savedTimeZone
        } else {
            timeZoneIdentifier = Self.defaultTimeZoneIdentifier
        }

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
            followedIDs = []
        }

        watchedAiringIDs = Set(UserDefaults.standard.array(forKey: watchedKey) as? [Int] ?? [])

        cloudStateStore.synchronize()
        if let snapshot = cloudStateStore.load() {
            applyCloudSnapshotIfNewer(snapshot)
        } else if hasLocalUserState {
            persistUserStateToCloud()
        }
        cloudObserver = cloudStateStore.observeChanges { [weak self] snapshot in
            Task { @MainActor in
                self?.receiveCloudChange(snapshot)
            }
        }

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

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(identifier: Self.defaultTimeZoneIdentifier)!
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    func formattedScheduleDate(_ date: Date) -> String {
        formatted(date, template: "EEE d MMM")
    }

    func formattedReleaseDate(_ date: Date) -> String {
        formatted(date, template: "d MMM yyyy")
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
            } else if show.tvmazeID != nil || show.tmdbID != nil {
                Task { await refreshSchedule(for: show) }
            }
        }
        UserDefaults.standard.set(Array(followedIDs), forKey: followedKey)
        persistUserStateToCloud()
    }

    func isLoadingSchedule(for show: Show) -> Bool {
        loadingScheduleIDs.contains(show.id)
    }

    @discardableResult
    func refreshSchedule(for show: Show, includingHistory: Bool = false) async -> Bool {
        guard show.mediaType == .tvShow,
              show.tvmazeID != nil || show.tmdbID != nil,
              !loadingScheduleIDs.contains(show.id) else { return false }
        loadingScheduleIDs.insert(show.id)
        defer { loadingScheduleIDs.remove(show.id) }

        do {
            let episodes: [Airing]
            if show.tvmazeID != nil {
                episodes = try await client.episodes(
                    for: show,
                    includingHistory: includingHistory,
                    timeZone: timeZone
                )
            } else if show.tmdbID != nil {
                episodes = try await tmdbClient.episodes(
                    for: show,
                    includingHistory: includingHistory,
                    timeZone: timeZone
                )
            } else {
                episodes = []
            }
            guard followedIDs.contains(show.id) else { return false }
            let startOfToday = calendar.startOfDay(for: .now)
            let startOfLastWeek = calendar.date(
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
            return true
        } catch {
            // The subscription remains saved; a later refresh can retry the schedule.
            return false
        }
    }

    func refreshFollowedSchedules() async {
        guard !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }

        for show in followedShows where show.mediaType == .tvShow
            && (show.tvmazeID != nil || show.tmdbID != nil) {
            await refreshSchedule(for: show)
        }
    }

    func loadPreviousSeasons() async {
        guard !hasLoadedHistory, !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }

        let trackableShows = followedShows.filter {
            $0.mediaType == .tvShow && ($0.tvmazeID != nil || $0.tmdbID != nil)
        }
        var loadedEveryShow = true
        for show in trackableShows {
            let loaded = await refreshSchedule(for: show, includingHistory: true)
            loadedEveryShow = loadedEveryShow && loaded
        }
        hasLoadedHistory = loadedEveryShow
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
        persistWatchedState()
    }

    func markSeasonWatched(containing airing: Airing) async {
        guard airing.season > 0 else {
            if !isWatched(airing) {
                watchedAiringIDs.insert(airing.id)
                persistWatchedState()
            }
            return
        }

        let show = show(for: airing.showID)
        if show.tvmazeID != nil || show.tmdbID != nil {
            await refreshSchedule(for: show, includingHistory: true)
        }

        let airedEpisodeIDs = airings.lazy
            .filter { episode in
                episode.showID == airing.showID
                    && episode.season == airing.season
                    && episode.episode > 0
                    && episode.airDate.map { $0 <= Date.now } == true
            }
            .map(\.id)

        watchedAiringIDs.formUnion(airedEpisodeIDs)
        persistWatchedState()
    }

    private func persistWatchedState() {
        UserDefaults.standard.set(Array(watchedAiringIDs), forKey: watchedKey)
        persistUserStateToCloud()
    }

    func sections(matching filter: MediaFilter = .all) -> [AiringSection] {
        let startOfToday = calendar.startOfDay(for: .now)
        let startOfThisWeek = calendar.dateInterval(
            of: .weekOfYear,
            for: startOfToday
        )!.start
        let startOfLastWeek = calendar.date(
            byAdding: .weekOfYear,
            value: -1,
            to: startOfThisWeek
        )!
        let startOfNextWeek = calendar.date(
            byAdding: .weekOfYear,
            value: 1,
            to: startOfThisWeek
        )!
        let source = followedAirings.filter { airing in
            guard filter.includes(show(for: airing.showID)) else { return false }
            guard let date = airing.airDate else { return true }
            if date >= startOfThisWeek, date < startOfToday { return false }
            if hasLoadedHistory { return true }
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

        let grouped = Dictionary(grouping: sorted) { airing -> String in
            guard let date = airing.airDate else { return "Date TBA" }
            if date >= startOfLastWeek, date < startOfThisWeek { return "Last week" }
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInTomorrow(date) { return "Tomorrow" }
            if date >= startOfThisWeek, date < startOfNextWeek {
                return "This week"
            }
            return formatted(date, template: "MMMM yyyy")
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

    private func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
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

    private var hasLocalUserState: Bool {
        UserDefaults.standard.object(forKey: followedKey) != nil
            || UserDefaults.standard.object(forKey: watchedKey) != nil
            || UserDefaults.standard.object(forKey: savedShowsKey) != nil
    }

    private func persistUserStateToCloud() {
        guard !isApplyingCloudState else { return }
        let modifiedAt = Date().timeIntervalSince1970
        let demoIDs = Set(DemoData.shows.map(\.id))
        let subscribedRemoteShows = shows.filter {
            followedIDs.contains($0.id) && !demoIDs.contains($0.id)
        }
        let snapshot = CloudStateSnapshot(
            version: 1,
            modifiedAt: modifiedAt,
            followedIDs: followedIDs.sorted(),
            watchedAiringIDs: watchedAiringIDs.sorted(),
            savedShows: subscribedRemoteShows,
            timeZoneIdentifier: timeZoneIdentifier
        )
        UserDefaults.standard.set(modifiedAt, forKey: cloudModifiedAtKey)
        cloudStateStore.save(snapshot)
    }

    private func receiveCloudChange(_ snapshot: CloudStateSnapshot?) {
        guard let snapshot else {
            clearLocalStateAfterCloudDeletion()
            return
        }
        applyCloudSnapshotIfNewer(snapshot)
    }

    private func applyCloudSnapshotIfNewer(_ snapshot: CloudStateSnapshot) {
        let localModifiedAt = UserDefaults.standard.double(forKey: cloudModifiedAtKey)
        guard snapshot.version == 1, snapshot.modifiedAt > localModifiedAt else { return }

        isApplyingCloudState = true
        followedIDs = Set(snapshot.followedIDs)
        watchedAiringIDs = Set(snapshot.watchedAiringIDs)
        shows = DemoData.shows + snapshot.savedShows.filter { saved in
            !DemoData.shows.contains { $0.id == saved.id }
        }
        if TimeZone(identifier: snapshot.timeZoneIdentifier) != nil {
            timeZoneIdentifier = snapshot.timeZoneIdentifier
        }
        UserDefaults.standard.set(snapshot.followedIDs, forKey: followedKey)
        UserDefaults.standard.set(snapshot.watchedAiringIDs, forKey: watchedKey)
        Self.save(snapshot.savedShows, key: savedShowsKey)
        UserDefaults.standard.set(snapshot.modifiedAt, forKey: cloudModifiedAtKey)
        isApplyingCloudState = false
        Task { [weak self] in
            await self?.refreshFollowedSchedules()
        }
    }

    private func clearLocalStateAfterCloudDeletion() {
        guard UserDefaults.standard.object(forKey: cloudModifiedAtKey) != nil else { return }
        isApplyingCloudState = true
        followedIDs = []
        watchedAiringIDs = []
        loadingScheduleIDs = []
        shows = DemoData.shows
        airings = []
        hasLoadedHistory = false
        timeZoneIdentifier = Self.defaultTimeZoneIdentifier
        [followedKey, watchedKey, savedShowsKey, savedAiringsKey, timeZoneKey, cloudModifiedAtKey].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        isApplyingCloudState = false
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
        Show(id: 101, tvmazeID: 44933, title: "Severance", network: "Apple TV+", genres: ["Drama", "Mystery"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/548/1371406.jpg"), tintHex: "F4CF3B", summary: "Mark leads a team whose work memories have been surgically divided from their personal lives.", status: "Running"),
        Show(id: 102, tvmazeID: 54198, title: "The Bear", network: "FX / Hulu", genres: ["Drama", "Comedy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/629/1574642.jpg"), tintHex: "55A7D9", summary: "A young chef returns home to run his family's sandwich shop.", status: "Ended"),
        Show(id: 103, tvmazeID: 51394, title: "The White Lotus", network: "HBO", genres: ["Drama", "Comedy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/557/1393876.jpg"), tintHex: "E66B53", summary: "A week in the life of vacationers and employees at an exclusive resort.", status: "Running"),
        Show(id: 104, tvmazeID: 38052, title: "Silo", network: "Apple TV+", genres: ["Drama", "Science Fiction"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/631/1577677.jpg"), tintHex: "C69263", summary: "Thousands live underground, unaware of why the silo was built.", status: "Running"),
        Show(id: 105, tvmazeID: 52341, title: "Andor", network: "Disney+", genres: ["Drama", "Science Fiction"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/564/1411766.jpg"), tintHex: "E86C3D", summary: "The story of a rebellion taking shape against an empire.", status: "Ended"),
        Show(id: 106, tvmazeID: 45039, title: "Slow Horses", network: "Apple TV+", genres: ["Drama", "Thriller"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/593/1484384.jpg"), tintHex: "76A06A", summary: "A dysfunctional team of MI5 agents navigates the espionage world's smoke and mirrors.", status: "Running"),
        Show(id: 107, tvmazeID: 35951, title: "Foundation", network: "Apple TV+", genres: ["Drama", "Science Fiction"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/573/1433544.jpg"), tintHex: "B88DE1", summary: "Exiles work to rebuild civilization amid the fall of a galactic empire.", status: "Running"),
        Show(id: 108, tvmazeID: 54914, title: "Hacks", network: "Max", genres: ["Comedy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/621/1552621.jpg"), tintHex: "ED6D9E", summary: "A legendary comedian forms a dark mentorship with a young comedy writer.", status: "Ended"),
        Show(id: 109, tvmazeID: nil, title: "Dune: Part Two", network: "Warner Bros.", genres: ["Science Fiction", "Adventure"], imageName: nil, imageURL: nil, tintHex: "D4A45B", summary: "Paul Atreides joins the Fremen while confronting the forces that destroyed his family.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2024, 3, 1), runtime: 166),
        Show(id: 110, tvmazeID: nil, title: "Spider-Man: Across the Spider-Verse", network: "Sony Pictures", genres: ["Animation", "Adventure"], imageName: nil, imageURL: nil, tintHex: "E06C5F", summary: "Miles Morales travels across the Multiverse and meets other Spider-People.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2023, 6, 2), runtime: 141),
        Show(id: 111, tvmazeID: nil, title: "The Batman", network: "Warner Bros.", genres: ["Action", "Crime"], imageName: nil, imageURL: nil, tintHex: "B94742", summary: "Batman follows a trail of clues left by a killer targeting Gotham City.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2022, 3, 4), runtime: 176),
        Show(id: 112, tvmazeID: 69956, title: "Frieren: Beyond Journey's End", network: "NTV", genres: ["Anime", "Adventure", "Fantasy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/479/1198409.jpg"), tintHex: "A9B8E8", summary: "An elven mage retraces the journey she once shared with her companions and learns what their brief lives meant.", status: "To Be Determined"),
        Show(id: 113, tvmazeID: 64632, title: "Solo Leveling", network: "Tokyo MX", genres: ["Anime", "Action", "Fantasy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/497/1244908.jpg"), tintHex: "6D8CD8", summary: "Humanity's weakest hunter gains a mysterious ability that lets him level up without limit.", status: "Running"),
        Show(id: 114, tvmazeID: 48450, title: "Jujutsu Kaisen", network: "MBS", genres: ["Anime", "Action", "Supernatural"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/608/1521905.jpg"), tintHex: "D56C7C", summary: "A student joins a secret organization of sorcerers after becoming host to a powerful curse.", status: "Running"),
        Show(id: 115, tvmazeID: nil, tmdbID: 1_671_548, title: "Dear You", network: "China", genres: ["Drama", "Family"], imageName: nil, imageURL: nil, tintHex: "D9AF52", summary: "A grandson travels to Thailand to uncover a family story and find the grandfather he never knew.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2026, 6, 18), runtime: 118)
    ]

    static let airings: [Airing] = []
}
