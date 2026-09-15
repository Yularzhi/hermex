import Foundation

/// Native preview downloads are bounded even when the host omits Content-Length.
struct BotArtifactBuffer {
    static let maximumBytes = 25 * 1024 * 1024
    let limit: Int
    private(set) var data = Data()

    init(limit: Int = maximumBytes) { self.limit = limit }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw BotArtifactFailure.tooLarge }
        data.append(chunk)
    }
}

/// A redirect can point at a login page or another host. Neither is an artifact.
final class BotArtifactRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension BotEndpoint {
    static func artifactURL(base: URL, path: String, context: BotArtifactContext) throws -> URL {
        guard !context.profile.isEmpty, !context.sessionID.isEmpty else { throw BotArtifactFailure.invalidReference }
        let path = try BotArtifactReference.path(path, address: base)
        var parts = URLComponents(url: base.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "path", value: path),
                             URLQueryItem(name: "profile", value: context.profile),
                             URLQueryItem(name: "session_id", value: context.sessionID)]
        guard let url = parts?.url else { throw BotArtifactFailure.invalidReference }
        return url
    }

    /// Uses the Bot client's authenticated session. No webui endpoint or shared URLSession.
    static func downloadArtifact(session: URLSession, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request, delegate: BotArtifactRedirectGuard())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw BotArtifactFailure.unavailable }
        guard response.statusCode == 200 else {
            if [401, 403].contains(response.statusCode) { throw BotFailure.rejected(response.statusCode) }
            throw BotArtifactFailure.unavailable
        }
        guard response.expectedContentLength <= Int64(BotArtifactBuffer.maximumBytes) else { throw BotArtifactFailure.tooLarge }
        var buffer = BotArtifactBuffer()
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                try buffer.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        try buffer.append(chunk)
        guard !buffer.data.isEmpty else { throw BotArtifactFailure.unavailable }
        return buffer.data
    }
}
