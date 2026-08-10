import Foundation
import SwiftData

@Model
private final class StoredShowRecord {
    @Attribute(.unique) var id: Int
    var payload: Data

    init(id: Int, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@Model
private final class StoredAiringRecord {
    @Attribute(.unique) var id: Int
    var showID: Int
    var payload: Data

    init(id: Int, showID: Int, payload: Data) {
        self.id = id
        self.showID = showID
        self.payload = payload
    }
}

@Model
private final class StoredWatchRecord {
    @Attribute(.unique) var id: Int

    init(id: Int) {
        self.id = id
    }
}

@MainActor
final class LocalDataStore {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?() {
        do {
            if let supportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first {
                try FileManager.default.createDirectory(
                    at: supportURL,
                    withIntermediateDirectories: true
                )
            }
            let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
            let container = try ModelContainer(
                for: StoredShowRecord.self,
                StoredAiringRecord.self,
                StoredWatchRecord.self,
                configurations: configuration
            )
            context = ModelContext(container)
            context.autosaveEnabled = false
        } catch {
            return nil
        }
    }

    func loadShows() -> [Show] {
        (try? context.fetch(FetchDescriptor<StoredShowRecord>()))?.compactMap {
            try? decoder.decode(Show.self, from: $0.payload)
        } ?? []
    }

    func loadAirings() -> [Airing] {
        (try? context.fetch(FetchDescriptor<StoredAiringRecord>()))?.compactMap {
            try? decoder.decode(Airing.self, from: $0.payload)
        } ?? []
    }

    func loadWatchedIDs() -> Set<Int> {
        Set((try? context.fetch(FetchDescriptor<StoredWatchRecord>()))?.map(\.id) ?? [])
    }

    @discardableResult
    func replaceShows(_ shows: [Show]) -> Bool {
        guard let records = try? context.fetch(FetchDescriptor<StoredShowRecord>()) else {
            return false
        }
        let incoming = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existing = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for record in records where incoming[record.id] == nil {
            context.delete(record)
        }
        for show in shows {
            guard let payload = try? encoder.encode(show) else { continue }
            if let record = existing[show.id] {
                if record.payload != payload { record.payload = payload }
            } else {
                context.insert(StoredShowRecord(id: show.id, payload: payload))
            }
        }
        return save()
    }

    @discardableResult
    func replaceAirings(_ airings: [Airing], for showID: Int? = nil) -> Bool {
        let descriptor: FetchDescriptor<StoredAiringRecord>
        if let showID {
            let targetID = showID
            descriptor = FetchDescriptor(predicate: #Predicate {
                $0.showID == targetID
            })
        } else {
            descriptor = FetchDescriptor()
        }
        guard let records = try? context.fetch(descriptor) else {
            return false
        }
        let incoming = Dictionary(airings.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let existing = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for record in records where incoming[record.id] == nil {
            context.delete(record)
        }
        for airing in airings {
            guard let payload = try? encoder.encode(airing) else { continue }
            if let record = existing[airing.id] {
                if record.payload != payload { record.payload = payload }
                record.showID = airing.showID
            } else {
                context.insert(StoredAiringRecord(
                    id: airing.id,
                    showID: airing.showID,
                    payload: payload
                ))
            }
        }
        return save()
    }

    @discardableResult
    func upsertAirings(_ airings: [Airing]) -> Bool {
        guard !airings.isEmpty else { return true }
        for (showID, showAirings) in Dictionary(grouping: airings, by: \.showID) {
            let targetShowID = showID
            let descriptor = FetchDescriptor<StoredAiringRecord>(predicate: #Predicate {
                $0.showID == targetShowID
            })
            guard let records = try? context.fetch(descriptor) else { return false }
            let existing = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            for airing in showAirings {
                guard let payload = try? encoder.encode(airing) else { continue }
                if let record = existing[airing.id] {
                    if record.payload != payload { record.payload = payload }
                    record.showID = airing.showID
                } else {
                    context.insert(StoredAiringRecord(
                        id: airing.id,
                        showID: airing.showID,
                        payload: payload
                    ))
                }
            }
        }
        return save()
    }

    @discardableResult
    func replaceWatchedIDs(_ ids: Set<Int>) -> Bool {
        guard let records = try? context.fetch(FetchDescriptor<StoredWatchRecord>()) else {
            return false
        }
        let existing = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where !ids.contains(record.id) {
            context.delete(record)
        }
        for id in ids where existing[id] == nil {
            context.insert(StoredWatchRecord(id: id))
        }
        return save()
    }

    @discardableResult
    func updateWatchedIDs(adding: Set<Int>, removing: Set<Int>) -> Bool {
        let changedIDs = adding.union(removing)
        guard !changedIDs.isEmpty else { return true }

        for id in removing {
            let targetID = id
            var descriptor = FetchDescriptor<StoredWatchRecord>(predicate: #Predicate {
                $0.id == targetID
            })
            descriptor.fetchLimit = 1
            if let records = try? context.fetch(descriptor), let record = records.first {
                context.delete(record)
            }
        }
        for id in adding {
            context.insert(StoredWatchRecord(id: id))
        }
        return save()
    }

    func clear() {
        try? context.delete(model: StoredShowRecord.self)
        try? context.delete(model: StoredAiringRecord.self)
        try? context.delete(model: StoredWatchRecord.self)
        _ = save()
    }

    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }
}
