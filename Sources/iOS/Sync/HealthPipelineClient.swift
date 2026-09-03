import Foundation

/// Async HTTP client for the health pipeline API (tailnet only).
///
/// Default base URL is the pipeline host on the private tailnet:
/// `http://100.77.127.123:8788`. The iOS app needs an ATS exception for plain
/// HTTP (see `Resources/iOS/Info.plist` `NSAppTransportSecurity`).
public actor HealthPipelineClient {
    public struct Configuration: Sendable, Equatable {
        public var baseURL: URL

        public init(baseURL: URL = URL(string: "http://100.77.127.123:8788")!) {
            self.baseURL = baseURL
        }
    }

    public let configuration: Configuration
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(configuration: Configuration = Configuration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { try HealthPipelineDateCodingV1.decode($0) }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { try HealthPipelineDateCodingV1.encode($0, to: $1) }
        self.encoder = encoder
    }

    // MARK: - Endpoints

    public func health() async throws -> HealthPipelineStatusV1 {
        try await get(makeURL(path: "health"))
    }

    public func sessions(activityType: String? = nil, since: Date? = nil,
                         until: Date? = nil, limit: Int = 100) async throws -> [HealthPipelineSessionV1] {
        var query: [URLQueryItem] = []
        if let activityType {
            query.append(URLQueryItem(name: "type", value: activityType))
        }
        if let since {
            query.append(URLQueryItem(name: "since", value: HealthPipelineDateCodingV1.string(from: since)))
        }
        if let until {
            query.append(URLQueryItem(name: "until", value: HealthPipelineDateCodingV1.string(from: until)))
        }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        let response: HealthPipelineSessionsResponseV1 = try await get(makeURL(path: "sessions", query: query))
        return response.sessions
    }

    public func session(id: Int) async throws -> HealthPipelineSessionV1 {
        try await get(makeURL(path: "sessions/\(id)"))
    }

    public func heartRate(sessionID: Int, start: Date? = nil, end: Date? = nil) async throws -> [HealthPipelineHeartRatePointV1] {
        var query: [URLQueryItem] = []
        if let start {
            query.append(URLQueryItem(name: "start", value: HealthPipelineDateCodingV1.string(from: start)))
        }
        if let end {
            query.append(URLQueryItem(name: "end", value: HealthPipelineDateCodingV1.string(from: end)))
        }
        let response: HealthPipelineHeartRateResponseV1 = try await get(makeURL(path: "sessions/\(sessionID)/heartrate", query: query))
        return response.samples
    }

    public func samples(type: String, since: Date? = nil, until: Date? = nil,
                        limit: Int = 500) async throws -> [HealthPipelineSampleV1] {
        var query: [URLQueryItem] = [URLQueryItem(name: "type", value: type)]
        if let since {
            query.append(URLQueryItem(name: "since", value: HealthPipelineDateCodingV1.string(from: since)))
        }
        if let until {
            query.append(URLQueryItem(name: "until", value: HealthPipelineDateCodingV1.string(from: until)))
        }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        struct Response: Decodable, Sendable {
            let samples: [HealthPipelineSampleV1]
        }
        let response: Response = try await get(makeURL(path: "samples", query: query))
        return response.samples
    }

    /// Push HealthKit-style records (e.g. from Shortcuts automation or a
    /// future Watch relay). Server deduplicates idempotently.
    @discardableResult
    public func ingest(_ records: [HealthPipelineIngestRecordV1]) async throws -> HealthPipelineIngestResultV1 {
        struct Body: Encodable, Sendable {
            let records: [HealthPipelineIngestRecordV1]
        }
        return try await post(makeURL(path: "ingest"), body: Body(records: records))
    }

    /// Upload a sealed `.footysession` package blob. `digest` is the package
    /// digest (32 bytes) from `SessionDigestV1`.
    @discardableResult
    public func uploadPackage(sessionID: UUID, digest: Data, package: Data) async throws -> HealthPipelinePackageReceiptV1 {
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        var query: [URLQueryItem] = [
            URLQueryItem(name: "session_id", value: sessionID.uuidString.lowercased()),
            URLQueryItem(name: "digest", value: digestHex),
        ]
        var url = makeURL(path: "packages")
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            if let u = comps.url { url = u }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = package
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode(HealthPipelinePackageReceiptV1.self, from: data)
    }

    /// Download a sealed `.footysession` package previously uploaded.
    public func downloadPackage(sessionID: UUID) async throws -> Data {
        let url = makeURL(path: "packages/\(sessionID.uuidString.lowercased())")
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        return data
    }

    /// Push the football analytics document for one session.
    @discardableResult
    public func postAnalytics(sessionID: UUID, document: SessionAnalyticsV1) async throws -> HealthPipelineAnalyticsReceiptV1 {
        let query = [URLQueryItem(name: "session_id", value: sessionID.uuidString.lowercased())]
        var url = makeURL(path: "analytics")
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            if let u = comps.url { url = u }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(document)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode(HealthPipelineAnalyticsReceiptV1.self, from: data)
    }

    /// Fetch one analytics document; nil when the pipeline has never seen it.
    public func analytics(sessionID: UUID) async throws -> SessionAnalyticsV1? {
        do {
            return try await get(makeURL(path: "analytics/\(sessionID.uuidString.lowercased())"))
        } catch HealthPipelineErrorV1.httpStatus(404) {
            return nil
        }
    }

    /// All stored analytics documents, newest first.
    public func analyticsList() async throws -> [SessionAnalyticsV1] {
        let response: HealthPipelineAnalyticsListResponseV1 = try await get(makeURL(path: "analytics"))
        return response.analytics
    }

    // MARK: - Plumbing

    private func makeURL(path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: configuration.baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            comps?.queryItems = query
        }
        guard let url = comps?.url else {
            preconditionFailure("invalid pipeline URL for path \(path)")
        }
        return url
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ url: URL, body: B) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode(T.self, from: data)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HealthPipelineErrorV1.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HealthPipelineErrorV1.httpStatus(http.statusCode)
        }
    }
}
