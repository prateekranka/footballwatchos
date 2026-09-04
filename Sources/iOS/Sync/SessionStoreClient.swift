import Foundation

/// R2-backed reachable store; not tailnet.
public enum SessionStoreErrorV1: Error, @unchecked Sendable {
    case badResponse(Int)
    case invalidDigest
    case missingToken
    case badURL
    case decode(Error)
}

/// R2-backed reachable store; not tailnet.
public actor SessionStoreClient {
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL

        public init(
            baseURL: URL = URL(string: "https://football-session-store.prateekranka.workers.dev")!
        ) {
            self.baseURL = baseURL
        }
    }

    public struct MetaV1: Codable, Sendable, Equatable {
        public let sessionID: UUID
        public let digest: String
        public let byteCount: Int
        public let receivedUTC: String
    }

    public let configuration: Configuration
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.token = SessionStoreCredentials.token
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func uploadPackage(
        sessionID: UUID,
        digest: SessionDigestV1,
        package: Data
    ) async throws {
        guard digest.bytes.count == 32 else { throw SessionStoreErrorV1.invalidDigest }
        let url = try makeURL(path: "packages/\(sessionID.uuidString.lowercased())", query: [
            URLQueryItem(name: "digest", value: digest.hexString)
        ])
        var request = try authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = package
        let (data, response) = try await session.data(for: request)
        try validate(response)
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SessionStoreErrorV1.decode(error)
        }
    }

    public func downloadPackage(sessionID: UUID) async throws -> Data {
        let url = try makeURL(path: "packages/\(sessionID.uuidString.lowercased())")
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response)
        return data
    }

    public func meta(sessionID: UUID) async throws -> MetaV1 {
        let url = try makeURL(path: "packages/\(sessionID.uuidString.lowercased())/meta")
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response)
        do {
            return try decoder.decode(MetaV1.self, from: data)
        } catch {
            throw SessionStoreErrorV1.decode(error)
        }
    }

    public func list() async throws -> [MetaV1] {
        let url = try makeURL(path: "packages")
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response)
        do {
            return try decoder.decode([MetaV1].self, from: data)
        } catch {
            throw SessionStoreErrorV1.decode(error)
        }
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        guard !token.isEmpty, token != "REPLACE_ME" else {
            throw SessionStoreErrorV1.missingToken
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw SessionStoreErrorV1.badURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SessionStoreErrorV1.badURL }
        return url
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SessionStoreErrorV1.badResponse(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionStoreErrorV1.badResponse(http.statusCode)
        }
    }

    private func validate(_ response: URLResponse) throws {
        try Self.validate(response)
    }
}
