import Foundation

struct YuhaiinFlow: Decodable {
    let download: String
    let upload: String
}

struct YuhaiinInfo: Decodable {
    let version: String?
    let commit: String?
    let goVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case commit
        case goVersion = "goVersion"
    }
}

struct YuhaiinUpdateCheck: Decodable {
    let supported: Bool
    let channel: String
    let currentVersion: String
    let targetVersion: String
    let targetTag: String
    let releaseURL: String
    let releaseNotes: String
    let assetName: String
    let assetURL: String?
    let assetSHA256: String
    let updateAvailable: Bool
    let reason: String

    enum CodingKeys: String, CodingKey {
        case supported, channel, currentVersion, targetVersion, targetTag
        case releaseURL = "releaseUrl"
        case releaseNotes
        case assetName
        case assetURL = "assetUrl"
        case assetSHA256 = "assetSha256"
        case updateAvailable, reason
    }
}

struct YuhaiinUpdateStatus: Decodable {
    let running: Bool
    let stage: String
    let progress: Int
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let error: String
}

enum YuhaiinAPIError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("error.apiInvalidURL")
        case let .httpStatus(status):
            return L("error.apiHTTPStatus", String(status))
        case .invalidResponse:
            return L("error.apiInvalidResponse")
        }
    }
}

final class YuhaiinAPIClient {
    private struct EmptyRequest: Encodable {}
    private var authorizationHeader: String?
    private var port = 50051

    private struct UpdateCheckRequest: Encodable {
        let channel: String
        let includePrerelease: Bool
    }

    private struct UpdateApplyRequest: Encodable {
        let channel: String
        let targetTag: String
        let includePrerelease: Bool
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func setPort(_ port: Int) {
        guard (1...65535).contains(port) else { return }
        self.port = port
    }

    func setCredentials(_ credentials: YuhaiinAPICredentials?) {
        guard let credentials else {
            authorizationHeader = nil
            return
        }
        let value = "\(credentials.username):\(credentials.password)"
        authorizationHeader = Data(value.utf8).base64EncodedString()
    }

    func fetchFlow() async throws -> YuhaiinFlow {
        try await request(operation: "connections.total")
    }

    func fetchInfo() async throws -> YuhaiinInfo {
        try await request(operation: "info")
    }

    func checkYuhaiinUpdate(channel: String = "stable", includePrerelease: Bool = false) async throws -> YuhaiinUpdateCheck {
        try await request(
            operation: "update.check",
            body: UpdateCheckRequest(channel: channel, includePrerelease: includePrerelease)
        )
    }

    func fetchYuhaiinUpdateStatus() async throws -> YuhaiinUpdateStatus {
        try await request(operation: "update.status")
    }

    func applyYuhaiinUpdate(channel: String, targetTag: String, includePrerelease: Bool = false) async throws {
        _ = try await request(
            operation: "update.apply",
            body: UpdateApplyRequest(channel: channel, targetTag: targetTag, includePrerelease: includePrerelease)
        ) as EmptyResponse
    }

    private func request<T: Decodable>(operation: String) async throws -> T {
        try await request(operation: operation, body: EmptyRequest())
    }

    private func request<T: Decodable, Body: Encodable>(operation: String, body: Body) async throws -> T {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent("rpc")
            .appendingPathComponent(operation)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue("Basic \(authorizationHeader)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YuhaiinAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw YuhaiinAPIError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw YuhaiinAPIError.invalidResponse
        }
    }
}

private struct EmptyResponse: Decodable {}
