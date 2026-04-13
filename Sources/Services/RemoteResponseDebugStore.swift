import Foundation

struct RemoteResponseDebugSnapshot: Codable, Sendable {
    let createdAt: Date
    let endpoint: String
    let wireAPI: String
    let statusCode: Int?
    let body: String
}

@MainActor
final class RemoteResponseDebugStore {
    static let shared = RemoteResponseDebugStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "aigtd.remote-response-debug-snapshot"

    func save(
        endpoint: String,
        wireAPI: String,
        statusCode: Int?,
        body: String
    ) {
        let snapshot = RemoteResponseDebugSnapshot(
            createdAt: .now,
            endpoint: endpoint,
            wireAPI: wireAPI,
            statusCode: statusCode,
            body: body
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func saveRaw(
        endpoint: String,
        wireAPI: String,
        statusCode: Int?,
        data: Data
    ) {
        let body: String
        if let utf8 = String(data: data, encoding: .utf8), utf8.isEmpty == false {
            body = utf8
        } else {
            body = data.base64EncodedString()
        }
        save(endpoint: endpoint, wireAPI: wireAPI, statusCode: statusCode, body: body)
    }

    func load() -> RemoteResponseDebugSnapshot? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(RemoteResponseDebugSnapshot.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }
}
