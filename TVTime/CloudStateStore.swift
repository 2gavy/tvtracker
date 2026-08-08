import Foundation

struct CloudStateSnapshot: Codable {
    let version: Int
    let modifiedAt: TimeInterval
    let followedIDs: [Int]
    let watchedAiringIDs: [Int]
    let savedShows: [Show]
    let timeZoneIdentifier: String
}

final class CloudStateStore {
    private let key = "userStateSnapshot"
    private let store = NSUbiquitousKeyValueStore.default

    func synchronize() {
        store.synchronize()
    }

    func load() -> CloudStateSnapshot? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CloudStateSnapshot.self, from: data)
    }

    func save(_ snapshot: CloudStateSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store.set(data, forKey: key)
        store.synchronize()
    }

    func observeChanges(_ handler: @escaping (CloudStateSnapshot?) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            guard changedKeys?.contains(self.key) != false else { return }
            handler(self.load())
        }
    }
}
