import CryptoKit
import Foundation

/// R2-backed reachable store; not tailnet.
public enum SessionStoreErrorV1: Error, @unchecked Sendable {
    case badResponse(Int)
    case invalidDigest
    case missingToken
    case badURL
    case decode(Error)
    case unreadableFile
    case sessionMissing
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

    /// Packages larger than this use the chunked upload path (small fixed-size
    /// parts + server-side completion) instead of one single PUT, so a large
    /// game package never sits whole in Worker or phone memory.
    public static let chunkedThresholdBytes = 4 * 1024 * 1024
    /// Bytes per chunk on the chunked path. Well under the Worker 12 MiB cap.
    public static let chunkBytes = 8 * 1024 * 1024

    public struct ChunkedManifestV1: Decodable, Sendable {
        public let total: Int
        public let complete: Bool
        public let received: [Int]
    }

    /// Uploads a package in fixed-size parts, resuming already-received parts
    /// from the server manifest. Reads only one part into memory at a time.
    /// `progress` receives `(partsSent, partTotal)` after each part.
    public func uploadPackageChunked(
        sessionID: UUID,
        digest: SessionDigestV1,
        fileURL: URL,
        byteCount: Int,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard digest.bytes.count == 32 else { throw SessionStoreErrorV1.invalidDigest }
        guard byteCount > 0 else { throw SessionStoreErrorV1.unreadableFile }
        let partSize = Self.chunkBytes
        let total = (byteCount + partSize - 1) / partSize
        let fullHex = digest.hexString
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw SessionStoreErrorV1.unreadableFile
        }
        defer { try? handle.close() }
        var received: Set<Int> = []
        if let resumed = try? await fetchReceivedParts(sessionID: sessionID),
           resumed.total == total
        {
            received = resumed.received
        }
        for index in 0..<total {
            if received.contains(index) {
                progress?(index + 1, total)
                continue
            }
            let offset = index * partSize
            let count = min(partSize, byteCount - offset)
            let chunk: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                guard let read = try handle.read(upToCount: count), read.count == count else {
                    throw SessionStoreErrorV1.unreadableFile
                }
                chunk = read
            } catch {
                throw SessionStoreErrorV1.unreadableFile
            }
            let chunkHex = Data(SHA256.hash(data: chunk)).map { String(format: "%02x", $0) }.joined()
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    _ = try await uploadPart(
                        sessionID: sessionID,
                        index: index,
                        total: total,
                        chunk: chunk,
                        chunkDigestHex: chunkHex,
                        fullDigestHex: fullHex,
                        byteCount: byteCount
                    )
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 3 {
                        try await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt))
                    }
                }
            }
            if let lastError { throw lastError }
            progress?(index + 1, total)
        }
        _ = try await completeChunkedUpload(sessionID: sessionID)
    }

    public func fetchReceivedParts(sessionID: UUID) async throws -> (received: Set<Int>, total: Int) {
        let url = try makeURL(path: "packages/\(sessionID.uuidString.lowercased())/parts/manifest")
        let (data, response) = try await session.data(for: authorizedRequest(url: url))
        try validate(response)
        do {
            let manifest = try decoder.decode(ChunkedManifestV1.self, from: data)
            return (Set(manifest.received), manifest.total)
        } catch {
            throw SessionStoreErrorV1.decode(error)
        }
    }

    public func uploadPart(
        sessionID: UUID,
        index: Int,
        total: Int,
        chunk: Data,
        chunkDigestHex: String,
        fullDigestHex: String,
        byteCount: Int
    ) async throws -> (received: Int, total: Int) {
        let url = try makeURL(path: "packages/\(sessionID.uuidString.lowercased())/parts/\(index)", query: [
            URLQueryItem(name: "total", value: String(total)),
            URLQueryItem(name: "digest", value: chunkDigestHex),
            URLQueryItem(name: "fullDigest", value: fullDigestHex),
            URLQueryItem(name: "byteCount", value: String(byteCount)),
        ])
        var request = try authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = chunk
        let (data, response) = try await session.data(for: request)
        try validate(response)
        struct PartResponse: Decodable, Sendable {
            let received: Int
            let total: Int
        }
        do {
            let decoded = try decoder.decode(PartResponse.self, from: data)
            return (decoded.received, decoded.total)
        } catch {
            throw SessionStoreErrorV1.decode(error)
        }
    }

    public func completeChunkedUpload(sessionID: UUID) async throws -> MetaV1 {
        let url = try makeURL(path: "packages/\(sessionID.uuidString.lowercased())/parts/complete")
        var request = try authorizedRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response)
        do {
            return try decoder.decode(MetaV1.self, from: data)
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
            // The Worker wraps the array: {"packages": [...]}. Decode the
            // wrapper, not a bare array, or the payload JSON is rejected.
            struct ListResponse: Decodable, Sendable {
                let packages: [MetaV1]
            }
            return try decoder.decode(ListResponse.self, from: data).packages
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
