import Foundation
import UIKit

@MainActor
final class ShowStore: ObservableObject {
    static let defaultTimeZoneIdentifier = "Asia/Singapore"

    @Published private(set) var followedIDs: Set<Int> {
        didSet { invalidateTimelineCache() }
    }
    @Published private(set) var watchedAiringIDs: Set<Int> {
        didSet { invalidateWatchedCache() }
    }
    @Published private(set) var loadingScheduleIDs: Set<Int> = []
    @Published private(set) var isRefreshingSchedules = false
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var historyLoadedShowIDs: Set<Int> = [] {
        didSet { invalidateTimelineCache() }
    }
    @Published private(set) var isCurrentSeasonHistoryVisible = false {
        didSet { invalidateTimelineCache() }
    }

    @Published private(set) var shows: [Show] {
        didSet {
            showsByID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            invalidateTimelineCache()
        }
    }
    @Published private(set) var airings: [Airing] {
        didSet {
            rebuildAiringIndexes()
            invalidateTimelineCache()
            invalidateWatchedCache()
        }
    }
    @Published var timeZoneIdentifier: String {
        didSet {
            guard TimeZone(identifier: timeZoneIdentifier) != nil else {
                timeZoneIdentifier = Self.defaultTimeZoneIdentifier
                return
            }
            guard timeZoneIdentifier != oldValue else { return }
            UserDefaults.standard.set(timeZoneIdentifier, forKey: timeZoneKey)
            dateFormatters.removeAll()
            invalidateTimelineCache()
            persistUserStateToCloud()
            Task { [weak self] in
                await self?.refreshFollowedSchedules(force: true)
            }
        }
    }

    private let followedKey = "followedShowIDs"
    private let watchedKey = "watchedAiringIDs"
    private let savedShowsKey = "savedTVMazeShows"
    private let savedAiringsKey = "savedTVMazeAirings"
    private let localMigrationKey = "localRecordStoreMigrationV1"
    private let refreshDatesKey = "scheduleRefreshDates"
    private let resolvedTVMazeIDsKey = "resolvedTVMazeIDs"
    private let fullyLoadedSeasonsKey = "fullyLoadedSeasonKeys"
    private let scheduleCacheVersionKey = "scheduleCacheVersion"
    private let timeZoneKey = "scheduleTimeZoneIdentifier"
    private let cloudModifiedAtKey = "cloudStateModifiedAt"
    private let client = TVMazeClient()
    private let tmdbClient = TMDBClient()
    private let cloudStateStore = CloudStateStore()
    private let localDataStore: LocalDataStore?
    private var cloudObserver: NSObjectProtocol?
    private var isApplyingCloudState = false
    private var historyLoadCursor = 0
    private var historyBeforeSeason: [Int: Int] = [:]
    private var historyExhaustedShowIDs: Set<Int> = []
    private var fullyLoadedSeasons: Set<String> = [] {
        didSet {
            guard fullyLoadedSeasons != oldValue else { return }
            UserDefaults.standard.set(
                fullyLoadedSeasons.sorted(),
                forKey: fullyLoadedSeasonsKey
            )
        }
    }
    private var historySeasonOrder: [Int: [Int]] = [:]
    private var showsByID: [Int: Show] = [:]
    private var airingsByID: [Int: Airing] = [:]
    private var airingsByShowID: [Int: [Airing]] = [:]
    private var latestSeasonByShowID: [Int: Int] = [:]
    private var sectionCache: [MediaFilter: [AiringSection]] = [:]
    private var dateFormatters: [String: DateFormatter] = [:]
    private var watchedAiringsCache: [Airing]?
    private var watchedMinutesCache: Int?
    private var scheduleRefreshDates: [Int: Date] = [:]
    private var resolvedTVMazeIDs: [Int: Int] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let scheduleRefreshTTL: TimeInterval = 8 * 60 * 60
    private let maximumHistorySeasonsPerShow = 8
    private let confirmedUndatedRenewalTitles: Set<String> = ["severance"]

    init() {
        localDataStore = LocalDataStore()
        let savedTimeZone = UserDefaults.standard.string(forKey: timeZoneKey)
        if let savedTimeZone, TimeZone(identifier: savedTimeZone) != nil {
            timeZoneIdentifier = savedTimeZone
        } else {
            timeZoneIdentifier = Self.defaultTimeZoneIdentifier
        }

        let legacyShows: [Show] = Self.load([Show].self, key: savedShowsKey) ?? []
        let legacyAirings: [Airing] = Self.load([Airing].self, key: savedAiringsKey) ?? []
        let legacyWatchedIDs = Set(UserDefaults.standard.array(forKey: watchedKey) as? [Int] ?? [])
        Self.migrateLegacyStorageIfNeeded(
            store: localDataStore,
            shows: legacyShows,
            airings: legacyAirings,
            watchedIDs: legacyWatchedIDs,
            migrationKey: localMigrationKey,
            legacyKeys: [savedShowsKey, savedAiringsKey, watchedKey]
        )

        let savedShows = localDataStore?.loadShows() ?? legacyShows
        let savedAirings = localDataStore?.loadAirings() ?? legacyAirings
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

        watchedAiringIDs = localDataStore?.loadWatchedIDs() ?? legacyWatchedIDs
        fullyLoadedSeasons = Set(
            UserDefaults.standard.stringArray(forKey: fullyLoadedSeasonsKey) ?? []
        )
        showsByID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        rebuildAiringIndexes()
        scheduleRefreshDates = Self.loadRefreshDates(key: refreshDatesKey)
        resolvedTVMazeIDs = Self.loadIntegerMap(key: resolvedTVMazeIDsKey)
        repairIncompleteScheduleCacheIfNeeded()
        collapseDuplicateSubscriptions()
        pruneUnsubscribedAirings()

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
        for name in [
            UIApplication.didReceiveMemoryWarningNotification,
            UIApplication.didEnterBackgroundNotification
        ] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.releaseUnwatchedHistory()
                    if name == UIApplication.didReceiveMemoryWarningNotification {
                        await PosterImageLoader.shared.releaseMemory()
                    }
                }
            })
        }

        Task { [weak self] in
            await self?.refreshFollowedSchedules()
        }
    }

    var followedShows: [Show] {
        shows.filter { followedIDs.contains($0.id) }
    }

    var watchedAirings: [Airing] {
        if let watchedAiringsCache { return watchedAiringsCache }
        let result = airings
            .filter { watchedAiringIDs.contains($0.id) }
            .sorted { ($0.airDate ?? .distantPast) > ($1.airDate ?? .distantPast) }
        watchedAiringsCache = result
        return result
    }

    var watchedMinutes: Int {
        if let watchedMinutesCache { return watchedMinutesCache }
        let result = watchedAirings.reduce(0) { $0 + $1.runtime }
        watchedMinutesCache = result
        return result
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
        showsByID[id] ?? shows[0]
    }

    func isFollowing(_ show: Show) -> Bool {
        followedShows.contains { subscriptionMatches($0, show) }
    }

    func toggleFollow(_ show: Show) {
        let matchingSubscriptions = followedShows.filter {
            subscriptionMatches($0, show)
        }
        if !matchingSubscriptions.isEmpty {
            for subscription in matchingSubscriptions {
                removeSubscriptionState(for: subscription.id)
            }
            persistRefreshDates()
        } else {
            if !shows.contains(where: { $0.id == show.id }) {
                shows.append(show)
                persistRemoteShows()
            }
            followedIDs.insert(show.id)
            historyLoadedShowIDs.remove(show.id)
            historyBeforeSeason.removeValue(forKey: show.id)
            historyExhaustedShowIDs.remove(show.id)
            if show.mediaType == .movie {
                addMovieRelease(for: show)
            } else if show.tvmazeID != nil || show.tmdbID != nil {
                Task { await refreshSchedule(for: show, force: true) }
            }
        }
        updateHistoryCompletion()
        UserDefaults.standard.set(Array(followedIDs), forKey: followedKey)
        persistUserStateToCloud()
    }

    func isLoadingSchedule(for show: Show) -> Bool {
        loadingScheduleIDs.contains(show.id)
    }

    @discardableResult
    func refreshSchedule(for show: Show, force: Bool = false) async -> Bool {
        guard show.mediaType == .tvShow,
              show.tvmazeID != nil || show.tmdbID != nil,
              !loadingScheduleIDs.contains(show.id) else { return false }
        if !force,
           hasLoadedSeasonMetadata(for: show.id),
           let refreshedAt = scheduleRefreshDates[show.id],
           Date.now.timeIntervalSince(refreshedAt) < scheduleRefreshTTL {
            return true
        }
        loadingScheduleIDs.insert(show.id)
        defer { loadingScheduleIDs.remove(show.id) }

        do {
            let page: EpisodeSchedulePage
            if show.tvmazeID != nil {
                page = try await client.episodes(
                    for: show,
                    timeZone: timeZone
                )
            } else if tmdbClient.isConfigured || show.tmdbID == 283_848 {
                page = try await tmdbClient.episodes(
                    for: show,
                    timeZone: timeZone
                )
            } else if let resolvedShow = try await tvMazeMatch(for: show) {
                page = try await client.episodes(
                    for: resolvedShow,
                    timeZone: timeZone
                )
            } else {
                page = EpisodeSchedulePage(episodes: [], loadedSeasons: [])
            }
            guard followedIDs.contains(show.id) else { return false }
            var updatedAirings = airings
            updatedAirings.removeAll { airing in
                guard airing.showID == show.id else { return false }
                return airing.season == 0 || page.loadedSeasons.contains(airing.season)
            }
            updatedAirings.append(contentsOf: page.episodes)
            airings = updatedAirings
            let refreshedSeasonKeys = Set(page.loadedSeasons.map {
                seasonKey(showID: show.id, season: $0)
            })
            fullyLoadedSeasons.subtract(refreshedSeasonKeys)
            fullyLoadedSeasons.formUnion(page.loadedSeasons.map {
                seasonKey(showID: show.id, season: $0)
            })
            removeFutureWatchedAirings()
            persistRemoteAirings(for: show.id)
            scheduleRefreshDates[show.id] = .now
            persistRefreshDates()
            return true
        } catch {
            // The subscription remains saved; a later refresh can retry the schedule.
            return false
        }
    }

    func refreshFollowedSchedules(force: Bool = false) async {
        guard !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }

        var priorities: [Int: Date] = [:]
        for showID in followedIDs {
            for airing in airingsByShowID[showID] ?? [] {
                guard let date = airing.airDate, date >= .now else { continue }
                priorities[showID] = min(priorities[showID] ?? .distantFuture, date)
            }
        }
        let candidates = followedShows.filter {
            $0.mediaType == .tvShow
                && ($0.tvmazeID != nil || $0.tmdbID != nil)
                && (force || isScheduleStale(showID: $0.id))
        }
        .sorted {
            (priorities[$0.id] ?? .distantFuture)
                < (priorities[$1.id] ?? .distantFuture)
        }

        // One request at a time keeps radio, decoding, and persistence spikes low.
        for show in candidates {
            await refreshSchedule(for: show, force: force)
        }
    }

    func loadMoreHistory() async {
        guard !hasLoadedHistory, !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }

        let trackableShows = followedShows.filter {
            $0.mediaType == .tvShow && ($0.tvmazeID != nil || $0.tmdbID != nil)
        }
        let pendingShows = trackableShows.filter { !historyExhaustedShowIDs.contains($0.id) }
        guard !pendingShows.isEmpty else {
            hasLoadedHistory = true
            return
        }

        let show = pendingShows[historyLoadCursor % pendingShows.count]
        historyLoadCursor &+= 1
        let oldestLoadedSeason = (airingsByShowID[show.id] ?? []).lazy
            .filter { $0.season > 0 }
            .map(\.season)
            .min()
        let beforeSeason = historyBeforeSeason[show.id]
            ?? oldestLoadedSeason
            ?? Int.max

        do {
            let page: EpisodeHistoryPage?
            if show.tvmazeID != nil {
                page = try await client.previousSeasonEpisodes(
                    for: show,
                    beforeSeason: beforeSeason,
                    timeZone: timeZone
                )
            } else if tmdbClient.isConfigured || show.tmdbID == 283_848 {
                page = try await tmdbClient.previousSeasonEpisodes(
                    for: show,
                    beforeSeason: beforeSeason,
                    timeZone: timeZone
                )
            } else if let resolvedShow = try await tvMazeMatch(for: show) {
                page = try await client.previousSeasonEpisodes(
                    for: resolvedShow,
                    beforeSeason: beforeSeason,
                    timeZone: timeZone
                )
            } else {
                page = nil
            }

            if let page {
                var updatedAirings = airings
                updatedAirings.removeAll {
                    $0.showID == show.id && $0.season == page.season
                }
                updatedAirings.append(contentsOf: page.episodes)
                airings = updatedAirings
                historyLoadedShowIDs.insert(show.id)
                fullyLoadedSeasons.insert(seasonKey(showID: show.id, season: page.season))
                historyBeforeSeason[show.id] = page.season
                retainRecentHistorySeason(page.season, for: show.id)
                if !page.hasMore { historyExhaustedShowIDs.insert(show.id) }
                removeFutureWatchedAirings()
                persistRemoteAirings(for: show.id)
            } else {
                historyExhaustedShowIDs.insert(show.id)
            }
        } catch {
            // Advance to another subscription on the next upward page; this one can retry later.
        }
        updateHistoryCompletion()
    }

    @discardableResult
    func revealCurrentSeasonHistory() -> Bool {
        guard !isCurrentSeasonHistoryVisible else { return false }
        isCurrentSeasonHistoryVisible = true
        return true
    }

    func isWatched(_ airing: Airing) -> Bool {
        canMarkWatched(airing) && watchedAiringIDs.contains(airing.id)
    }

    func canMarkWatched(_ airing: Airing) -> Bool {
        airing.airDate.map { $0 <= Date.now } == true
    }

    func canMarkSeasonWatched(containing airing: Airing) -> Bool {
        guard airing.season > 0,
              fullyLoadedSeasons.contains(
                  seasonKey(showID: airing.showID, season: airing.season)
              ) else { return false }
        let seasonEpisodes = (airingsByShowID[airing.showID] ?? []).filter {
            $0.season == airing.season
                && $0.episode > 0
        }
        return !seasonEpisodes.isEmpty && seasonEpisodes.allSatisfy(canMarkWatched)
    }

    func canMarkAiredSeasonEpisodes(containing airing: Airing) -> Bool {
        guard airing.season > 0,
              fullyLoadedSeasons.contains(
                  seasonKey(showID: airing.showID, season: airing.season)
              ) else { return false }
        return (airingsByShowID[airing.showID] ?? []).contains { episode in
            episode.season == airing.season
                && episode.episode > 0
                && canMarkWatched(episode)
                && !watchedAiringIDs.contains(episode.id)
        }
    }

    func toggleWatched(_ airing: Airing) {
        if watchedAiringIDs.contains(airing.id) {
            watchedAiringIDs.remove(airing.id)
            persistWatchedDelta(removing: [airing.id])
        } else {
            guard canMarkWatched(airing) else { return }
            watchedAiringIDs.insert(airing.id)
            persistWatchedDelta(adding: [airing.id], storing: [airing])
        }
    }

    func markSeasonWatched(containing airing: Airing) {
        guard airing.season > 0 else { return }

        guard canMarkSeasonWatched(containing: airing) else { return }

        markAiredSeasonEpisodesWatched(containing: airing)
    }

    func markAiredSeasonEpisodesWatched(containing airing: Airing) {
        guard canMarkAiredSeasonEpisodes(containing: airing) else { return }

        let airedEpisodes = (airingsByShowID[airing.showID] ?? []).filter { episode in
            episode.season == airing.season
                && episode.episode > 0
                && episode.airDate.map { $0 <= Date.now } == true
        }
        let airedEpisodeIDs = airedEpisodes.lazy
            .filter { episode in
                !self.watchedAiringIDs.contains(episode.id)
            }
            .map(\.id)

        watchedAiringIDs.formUnion(airedEpisodeIDs)
        persistWatchedDelta(
            adding: Set(airedEpisodeIDs),
            storing: airedEpisodes
        )
    }

    private func persistWatchedDelta(
        adding: Set<Int> = [],
        removing: Set<Int> = [],
        storing airings: [Airing] = []
    ) {
        localDataStore?.updateWatchedIDs(adding: adding, removing: removing)
        if !airings.isEmpty { localDataStore?.upsertAirings(airings) }
        persistUserStateToCloud()
    }

    private func removeFutureWatchedAirings() {
        let removed = Set(watchedAiringIDs.filter { id in
            airingsByID[id].map { !canMarkWatched($0) } == true
        })
        guard !removed.isEmpty else { return }
        watchedAiringIDs.subtract(removed)
        persistWatchedDelta(removing: removed)
    }

    func sections(matching filter: MediaFilter = .all) -> [AiringSection] {
        if let cached = sectionCache[filter] { return cached }
        let calendar = self.calendar
        let startOfToday = calendar.startOfDay(for: .now)
        let recentPastStart = calendar.date(
            byAdding: .day,
            value: -7,
            to: startOfToday
        )!
        let currentMonth = calendar.dateInterval(of: .month, for: startOfToday)!
        let latestSeasonByShow = isCurrentSeasonHistoryVisible
            ? latestEpisodeSeasonByShow()
            : [:]
        let followedAirings = followedIDs.flatMap { airingsByShowID[$0] ?? [] }
        var source = followedAirings.filter { airing in
            guard filter.includes(show(for: airing.showID)) else { return false }
            guard let date = airing.airDate else { return true }
            if historyLoadedShowIDs.contains(airing.showID) { return true }
            if airing.season > 0,
               latestSeasonByShow[airing.showID] == airing.season {
                return true
            }
            return date >= recentPastStart
        }
        let representedShowIDs = Set(source.map(\.showID))
        source.append(contentsOf: followedShows.compactMap { followedShow in
            let status = followedShow.status.lowercased()
            guard filter.includes(followedShow),
                  followedShow.mediaType == .tvShow,
                  confirmedUndatedRenewalTitles.contains(followedShow.title.lowercased()),
                  status != "ended",
                  status != "canceled",
                  status != "cancelled",
                  !representedShowIDs.contains(followedShow.id) else { return nil }
            return Airing(
                id: 8_500_000_000 + followedShow.id,
                showID: followedShow.id,
                season: 0,
                episode: 0,
                title: "Next season not announced",
                airDate: nil,
                runtime: followedShow.runtime,
                service: followedShow.network
            )
        })
        let sorted = source.sorted { lhs, rhs in
            switch (lhs.airDate, rhs.airDate) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return show(for: lhs.showID).title < show(for: rhs.showID).title
            }
        }

        let grouped = Dictionary(grouping: sorted) { airing -> String in
            guard let date = airing.airDate else { return "No date scheduled" }
            if date >= recentPastStart, date < startOfToday { return "Last week" }
            if calendar.isDateInToday(date) { return "Today" }
            if date > startOfToday, currentMonth.contains(date) { return "Later" }
            return formatted(date, template: "MMMM yyyy")
        }

        let sections = grouped.map { key, value in
            AiringSection(
                title: key,
                subtitle: key == "No date scheduled"
                    ? "Renewed or continuing shows awaiting a date"
                    : nil,
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
        sectionCache[filter] = sections
        return sections
    }

    private func persistRemoteShows() {
        let demoIDs = Set(DemoData.shows.map(\.id))
        let remote = shows.filter { !demoIDs.contains($0.id) }
        localDataStore?.replaceShows(remote)
    }

    private func formatted(_ date: Date, template: String) -> String {
        let key = "\(timeZoneIdentifier):\(template)"
        let formatter: DateFormatter
        if let cached = dateFormatters[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = .autoupdatingCurrent
            created.timeZone = timeZone
            created.setLocalizedDateFormatFromTemplate(template)
            dateFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }

    private func addMovieRelease(for show: Show) {
        guard airingsByShowID[show.id]?.isEmpty != false else { return }
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
        persistRemoteAirings(for: show.id)
    }

    private func persistRemoteAirings(for showID: Int? = nil) {
        let cutoff = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        let latestSeasonByShow = latestEpisodeSeasonByShow()
        let source: [Airing]
        if let showID {
            source = airingsByShowID[showID] ?? []
        } else {
            source = airings
        }
        let retained = source.filter { airing in
            guard airing.id > 1_000_000_000 else { return false }
            if watchedAiringIDs.contains(airing.id) { return true }
            if airing.season > 0,
               latestSeasonByShow[airing.showID] == airing.season {
                return true
            }
            guard let date = airing.airDate else { return true }
            return date >= cutoff
        }
        localDataStore?.replaceAirings(retained, for: showID)
    }

    private func releaseUnwatchedHistory() {
        let cutoff = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
        let latestSeasonByShow = latestEpisodeSeasonByShow()
        let retainedAirings = airings.filter { airing in
            if !followedIDs.contains(airing.showID) {
                return watchedAiringIDs.contains(airing.id)
            }
            guard !watchedAiringIDs.contains(airing.id),
                  let date = airing.airDate else { return true }
            if airing.season > 0,
               latestSeasonByShow[airing.showID] == airing.season {
                return true
            }
            return date >= cutoff
        }
        let removedStoredHistory = retainedAirings.count != airings.count
        if removedStoredHistory { airings = retainedAirings }
        if !historyLoadedShowIDs.isEmpty { historyLoadedShowIDs = [] }
        historyBeforeSeason = [:]
        historyExhaustedShowIDs = []
        for (showID, seasons) in historySeasonOrder {
            for season in seasons {
                fullyLoadedSeasons.remove(seasonKey(showID: showID, season: season))
            }
        }
        historySeasonOrder = [:]
        historyLoadCursor = 0
        updateHistoryCompletion()
        if removedStoredHistory { persistRemoteAirings() }
    }

    private func collapseDuplicateSubscriptions() {
        let groups = Dictionary(grouping: followedShows, by: subscriptionKey)
        var removedIDs: Set<Int> = []
        for duplicates in groups.values where duplicates.count > 1 {
            let winner = duplicates.max { left, right in
                let leftCount = airingsByShowID[left.id]?.count ?? 0
                let rightCount = airingsByShowID[right.id]?.count ?? 0
                if leftCount != rightCount { return leftCount < rightCount }
                return left.id < right.id
            }
            removedIDs.formUnion(duplicates.lazy.filter { $0.id != winner?.id }.map(\.id))
        }
        guard !removedIDs.isEmpty else { return }
        for id in removedIDs { removeSubscriptionState(for: id) }
        UserDefaults.standard.set(Array(followedIDs), forKey: followedKey)
        persistRefreshDates()
    }

    private func pruneUnsubscribedAirings() {
        let retained = airings.filter {
            followedIDs.contains($0.showID) || watchedAiringIDs.contains($0.id)
        }
        guard retained.count != airings.count else { return }
        airings = retained
        persistRemoteAirings()
    }

    private func removeSubscriptionState(for showID: Int) {
        followedIDs.remove(showID)
        scheduleRefreshDates.removeValue(forKey: showID)
        historyLoadedShowIDs.remove(showID)
        historyBeforeSeason.removeValue(forKey: showID)
        historyExhaustedShowIDs.remove(showID)
        historySeasonOrder.removeValue(forKey: showID)
        fullyLoadedSeasons = fullyLoadedSeasons.filter { !$0.hasPrefix("\(showID):") }

        let retained = airings.filter {
            $0.showID != showID || watchedAiringIDs.contains($0.id)
        }
        if retained.count != airings.count {
            airings = retained
            persistRemoteAirings(for: showID)
        }
    }

    private func subscriptionMatches(_ left: Show, _ right: Show) -> Bool {
        left.id == right.id || subscriptionKey(left) == subscriptionKey(right)
    }

    private func subscriptionKey(_ show: Show) -> String {
        if let tvmazeID = show.tvmazeID { return "tvmaze:\(tvmazeID)" }
        if let tmdbID = show.tmdbID { return "tmdb:\(tmdbID):\(show.mediaType.rawValue)" }
        return "local:\(show.id)"
    }

    private func updateHistoryCompletion() {
        let trackableIDs = Set(followedShows.lazy.filter {
            $0.mediaType == .tvShow && ($0.tvmazeID != nil || $0.tmdbID != nil)
        }.map(\.id))
        let retainedLoadedIDs = historyLoadedShowIDs.intersection(trackableIDs)
        if retainedLoadedIDs != historyLoadedShowIDs {
            historyLoadedShowIDs = retainedLoadedIDs
        }
        historyExhaustedShowIDs.formIntersection(trackableIDs)
        let isComplete = trackableIDs.isSubset(of: historyExhaustedShowIDs)
        if hasLoadedHistory != isComplete { hasLoadedHistory = isComplete }
    }

    private func seasonKey(showID: Int, season: Int) -> String {
        "\(showID):\(season)"
    }

    private var hasLocalUserState: Bool {
        UserDefaults.standard.object(forKey: followedKey) != nil
            || UserDefaults.standard.object(forKey: watchedKey) != nil
            || UserDefaults.standard.object(forKey: savedShowsKey) != nil
    }

    private func persistUserStateToCloud() {
        guard !isApplyingCloudState, cloudStateStore.isAvailable else { return }
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
        historyLoadedShowIDs = []
        historyLoadCursor = 0
        historyBeforeSeason = [:]
        historyExhaustedShowIDs = []
        fullyLoadedSeasons = []
        watchedAiringIDs = Set(snapshot.watchedAiringIDs)
        shows = DemoData.shows + snapshot.savedShows.filter { saved in
            !DemoData.shows.contains { $0.id == saved.id }
        }
        collapseDuplicateSubscriptions()
        pruneUnsubscribedAirings()
        if TimeZone(identifier: snapshot.timeZoneIdentifier) != nil {
            timeZoneIdentifier = snapshot.timeZoneIdentifier
        }
        UserDefaults.standard.set(Array(followedIDs), forKey: followedKey)
        localDataStore?.replaceWatchedIDs(watchedAiringIDs)
        persistRemoteShows()
        UserDefaults.standard.set(snapshot.modifiedAt, forKey: cloudModifiedAtKey)
        isApplyingCloudState = false
        persistUserStateToCloud()
        updateHistoryCompletion()
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
        historyLoadedShowIDs = []
        historyLoadCursor = 0
        historyBeforeSeason = [:]
        historyExhaustedShowIDs = []
        historySeasonOrder = [:]
        fullyLoadedSeasons = []
        timeZoneIdentifier = Self.defaultTimeZoneIdentifier
        [
            followedKey, watchedKey, savedShowsKey, savedAiringsKey,
            timeZoneKey, cloudModifiedAtKey, refreshDatesKey,
            fullyLoadedSeasonsKey, resolvedTVMazeIDsKey
        ].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        scheduleRefreshDates = [:]
        resolvedTVMazeIDs = [:]
        localDataStore?.clear()
        isApplyingCloudState = false
    }

    private func invalidateTimelineCache() {
        sectionCache.removeAll(keepingCapacity: true)
    }

    private func invalidateWatchedCache() {
        watchedAiringsCache = nil
        watchedMinutesCache = nil
    }

    private func rebuildAiringIndexes() {
        airingsByID = Dictionary(
            airings.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        airingsByShowID = Dictionary(grouping: airings, by: \.showID)
        var latest: [Int: Int] = [:]
        for airing in airings where airing.season > 0 && airing.episode > 0 {
            latest[airing.showID] = max(latest[airing.showID] ?? 0, airing.season)
        }
        latestSeasonByShowID = latest
    }

    private func isScheduleStale(showID: Int) -> Bool {
        guard hasLoadedSeasonMetadata(for: showID) else { return true }
        guard let refreshedAt = scheduleRefreshDates[showID] else { return true }
        return Date.now.timeIntervalSince(refreshedAt) >= scheduleRefreshTTL
    }

    private func hasLoadedSeasonMetadata(for showID: Int) -> Bool {
        let seasonPrefix = "\(showID):"
        return fullyLoadedSeasons.contains { $0.hasPrefix(seasonPrefix) }
    }

    private func persistRefreshDates() {
        let payload = Dictionary(uniqueKeysWithValues: scheduleRefreshDates.map {
            (String($0.key), $0.value.timeIntervalSince1970)
        })
        UserDefaults.standard.set(payload, forKey: refreshDatesKey)
    }

    private func tvMazeMatch(for show: Show) async throws -> Show? {
        if let tvmazeID = resolvedTVMazeIDs[show.id] {
            return show.withTVMazeID(tvmazeID)
        }
        guard let resolved = try await client.matchingShow(for: show),
              let tvmazeID = resolved.tvmazeID else { return nil }
        resolvedTVMazeIDs[show.id] = tvmazeID
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: resolvedTVMazeIDs.map {
                (String($0.key), $0.value)
            }),
            forKey: resolvedTVMazeIDsKey
        )
        return resolved
    }

    private func latestEpisodeSeasonByShow() -> [Int: Int] {
        latestSeasonByShowID
    }

    private func repairIncompleteScheduleCacheIfNeeded() {
        let currentVersion = 4
        guard UserDefaults.standard.integer(forKey: scheduleCacheVersionKey) < currentVersion else {
            return
        }
        fullyLoadedSeasons = []
        scheduleRefreshDates = [:]
        UserDefaults.standard.removeObject(forKey: refreshDatesKey)
        UserDefaults.standard.set(currentVersion, forKey: scheduleCacheVersionKey)
    }

    private func retainRecentHistorySeason(_ season: Int, for showID: Int) {
        var order = historySeasonOrder[showID, default: []]
        if !order.contains(season) { order.append(season) }
        while order.count > maximumHistorySeasonsPerShow {
            let evicted = order.removeFirst()
            airings.removeAll {
                $0.showID == showID
                    && $0.season == evicted
                    && !watchedAiringIDs.contains($0.id)
            }
            fullyLoadedSeasons.remove(seasonKey(showID: showID, season: evicted))
        }
        historySeasonOrder[showID] = order
    }

    private static func loadRefreshDates(key: String) -> [Int: Date] {
        guard let payload = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: payload.compactMap { key, value in
            Int(key).map { ($0, Date(timeIntervalSince1970: value)) }
        })
    }

    private static func loadIntegerMap(key: String) -> [Int: Int] {
        guard let payload = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        return Dictionary(uniqueKeysWithValues: payload.compactMap { key, value in
            guard let integerKey = Int(key), let integerValue = value as? Int else { return nil }
            return (integerKey, integerValue)
        })
    }

    private static func migrateLegacyStorageIfNeeded(
        store: LocalDataStore?,
        shows: [Show],
        airings: [Airing],
        watchedIDs: Set<Int>,
        migrationKey: String,
        legacyKeys: [String]
    ) {
        guard let store,
              !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        let succeeded = store.replaceShows(shows)
            && store.replaceAirings(airings)
            && store.replaceWatchedIDs(watchedIDs)
        guard succeeded else { return }
        legacyKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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
        Show(id: 109, tvmazeID: nil, title: "Dune: Part Two", network: "Warner Bros.", genres: ["Science Fiction", "Adventure"], imageName: nil, imageURL: URL(string: "https://image.tmdb.org/t/p/w342/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg"), tintHex: "D4A45B", summary: "Paul Atreides joins the Fremen while confronting the forces that destroyed his family.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2024, 3, 1), runtime: 166),
        Show(id: 110, tvmazeID: nil, title: "Spider-Man: Across the Spider-Verse", network: "Sony Pictures", genres: ["Animation", "Adventure"], imageName: nil, imageURL: URL(string: "https://image.tmdb.org/t/p/w342/8Vt6mWEReuy4Of61Lnj5Xj704m8.jpg"), tintHex: "E06C5F", summary: "Miles Morales travels across the Multiverse and meets other Spider-People.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2023, 6, 2), runtime: 141),
        Show(id: 111, tvmazeID: nil, title: "The Batman", network: "Warner Bros.", genres: ["Action", "Crime"], imageName: nil, imageURL: URL(string: "https://image.tmdb.org/t/p/w342/74xTEgt7R36Fpooo50r9T25onhq.jpg"), tintHex: "B94742", summary: "Batman follows a trail of clues left by a killer targeting Gotham City.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2022, 3, 4), runtime: 176),
        Show(id: 112, tvmazeID: 69956, title: "Frieren: Beyond Journey's End", network: "NTV", genres: ["Anime", "Adventure", "Fantasy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/479/1198409.jpg"), tintHex: "A9B8E8", summary: "An elven mage retraces the journey she once shared with her companions and learns what their brief lives meant.", status: "To Be Determined"),
        Show(id: 113, tvmazeID: 64632, title: "Solo Leveling", network: "Tokyo MX", genres: ["Anime", "Action", "Fantasy"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/497/1244908.jpg"), tintHex: "6D8CD8", summary: "Humanity's weakest hunter gains a mysterious ability that lets him level up without limit.", status: "Running"),
        Show(id: 114, tvmazeID: 48450, title: "Jujutsu Kaisen", network: "MBS", genres: ["Anime", "Action", "Supernatural"], imageName: nil, imageURL: URL(string: "https://static.tvmaze.com/uploads/images/medium_portrait/608/1521905.jpg"), tintHex: "D56C7C", summary: "A student joins a secret organization of sorcerers after becoming host to a powerful curse.", status: "Running"),
        Show(id: 115, tvmazeID: nil, tmdbID: 1_671_548, title: "Dear You", network: "China", genres: ["Drama", "Family"], imageName: nil, imageURL: URL(string: "https://image.tmdb.org/t/p/w342/rjmhzdVS3Ia535pFawju857e2Na.jpg"), tintHex: "D9AF52", summary: "A grandson travels to Thailand to uncover a family story and find the grandfather he never knew.", status: "Released", mediaType: .movie, releaseDate: releaseDate(2026, 6, 18), runtime: 118)
    ]

    static let airings: [Airing] = []
}
