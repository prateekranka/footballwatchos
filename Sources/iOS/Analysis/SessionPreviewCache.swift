import Foundation

/// A cached, derived visual summary of one Football Session.
///
/// Everything in this type is computed from a bounded package scan; it never
/// contains raw high-frequency samples. It exists so session rows and the
/// featured card can show a fingerprint and one factual observation without
/// decoding a whole package.
struct SessionVisualSummary: Codable, Equatable, Sendable {
    let sessionID: UUID
    /// Package digest this summary was computed from. A re-imported package
    /// invalidates the cache by digest change.
    let packageDigestHex: String
    let analysisVersion: Int
    /// Heart-rate fingerprint bins; `nil` when evidence is missing, too
    /// short, or the bounded scan had to truncate its input.
    let fingerprint: SessionFingerprintV1?
    /// At most one factual observation; `nil` when evidence is insufficient.
    let observation: SessionObservationV1?
    /// Recorded heart-rate range across snapshots, when present.
    let heartRateRange: ClosedRange<Double>?
    let heartRateSampleCount: Int
    let distanceSampleCount: Int
    let computedAt: Date

    /// Bumped whenever derived presentation rules change.
    static let currentAnalysisVersion = 2
}

/// Computes and caches `SessionVisualSummary` values off the main actor.
///
/// The cache is a small JSON sidecar per session, keyed by package digest
/// and analysis version, so a changed or re-imported package recomputes
/// rather than presenting stale evidence.
actor SessionPreviewStore {

    private struct CacheEntry: Codable {
        let summary: SessionVisualSummary
    }

    private var cacheDirectory: URL?
    private var inMemory: [UUID: SessionVisualSummary] = [:]
    /// Sessions currently queued for computation, processed serially.
    private var inFlight: Set<UUID> = []

    init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("FootballPerformance", isDirectory: true)
                .appendingPathComponent("Previews", isDirectory: true)
        }
    }

    /// Already-computed summaries, safe to publish.
    func snapshot() -> [UUID: SessionVisualSummary] {
        inMemory
    }

    func cachedSummary(for sessionID: UUID) -> SessionVisualSummary? {
        inMemory[sessionID]
    }

    /// Ensures summaries exist for the given records, newest first.
    /// `budget` bounds how many expensive scans may start per call so a
    /// large library never turns a screen load into a scan storm.
    func prepare(
        records: [FileSessionRepository.SessionRecord],
        repository: FileSessionRepository,
        budget: Int
    ) async {
        for record in records.prefix(budget) {
            if inMemory[record.sessionID]?.packageDigestHex == record.packageDigest.hexString {
                continue
            }
            if inFlight.contains(record.sessionID) {
                continue
            }
            inFlight.insert(record.sessionID)
            // Disk sidecar first; a previous launch may already have paid
            // for this scan.
            var summary = readSidecar(sessionID: record.sessionID, digestHex: record.packageDigest.hexString)
            if summary == nil {
                summary = await computeSummary(for: record, repository: repository)
            }
            inFlight.remove(record.sessionID)
            if let summary {
                inMemory[summary.sessionID] = summary
                if readSidecar(sessionID: summary.sessionID, digestHex: summary.packageDigestHex) == nil {
                    writeSidecar(summary)
                }
            }
        }
    }

    /// Computes one summary with a bounded scan. Failures return `nil` and
    /// are silent by design; rows simply show no fingerprint.
    private func computeSummary(
        for record: FileSessionRepository.SessionRecord,
        repository: FileSessionRepository
    ) async -> SessionVisualSummary? {
        guard let url = try? await repository.packageLocation(for: record.sessionID) else {
            return nil
        }
        guard let scan = try? FootySessionPackageV1.scanBoundedSnapshots(of: url) else {
            return nil
        }

        let endedAt = record.completion.endedAt
        let startedAt = record.sessionEnvelope.startedAt

        // Truncated input would make bins describe only part of the session,
        // so both derived visuals are withheld rather than partial.
        var fingerprint: SessionFingerprintV1?
        var observation: SessionObservationV1?
        if !scan.heartRateTruncated, !scan.distanceTruncated {
            fingerprint = SessionFingerprintV1.build(
                from: scan.heartRateSnapshots.map { ($0.timestamp, $0.value) },
                startedAt: startedAt,
                endedAt: endedAt
            )
            if let fingerprint {
                observation = SessionObservationEngineV1.busiestStretch(from: fingerprint)
            }
        }

        let heartRates = scan.heartRateSnapshots.map(\.value)
        let heartRateRange: ClosedRange<Double>? = heartRates.isEmpty
            ? nil
            : (heartRates.min()!...heartRates.max()!)

        return SessionVisualSummary(
            sessionID: record.sessionID,
            packageDigestHex: record.packageDigest.hexString,
            analysisVersion: SessionVisualSummary.currentAnalysisVersion,
            fingerprint: fingerprint,
            observation: observation,
            heartRateRange: heartRateRange,
            heartRateSampleCount: scan.heartRateSnapshots.count,
            distanceSampleCount: scan.distanceSnapshots.count,
            computedAt: Date()
        )
    }

    // MARK: - Sidecar persistence

    private func sidecarURL(for summary: SessionVisualSummary) -> URL? {
        cacheDirectory?.appendingPathComponent(
            "\(summary.sessionID.uuidString.lowercased())-"
                + "\(summary.packageDigestHex.prefix(16))-"
                + "v\(summary.analysisVersion).json",
            isDirectory: false
        )
    }

    private func writeSidecar(_ summary: SessionVisualSummary) {
        guard let url = sidecarURL(for: summary) else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CacheEntry(summary: summary))
            try data.write(to: url, options: .atomic)
        } catch {
            // A failed sidecar write only costs a recompute later.
        }
    }

    private func readSidecar(
        sessionID: UUID,
        digestHex: String
    ) -> SessionVisualSummary? {
        let url = cacheDirectory?.appendingPathComponent(
            "\(sessionID.uuidString.lowercased())-\(digestHex.prefix(16))-"
                + "v\(SessionVisualSummary.currentAnalysisVersion).json",
            isDirectory: false
        )
        guard let url, let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              entry.summary.packageDigestHex == digestHex,
              entry.summary.analysisVersion == SessionVisualSummary.currentAnalysisVersion else {
            return nil
        }
        return entry.summary
    }
}
