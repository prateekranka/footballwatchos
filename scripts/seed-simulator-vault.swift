import Foundation

/// QA seed tool: writes valid synthetic .footysession packages into an iOS
/// simulator app container so the redesigned UI can be inspected with real
/// decoding paths. Never points at a real device; simulator QA only.
///
/// Usage: seed-simulator-vault <vaultRoot> (the .../FootballPerformance dir)

// MARK: - Synthetic package construction

struct SeededSession {
    let startedAt: Date
    let durationMinutes: Int
    let distanceMeters: Double
    let averageHeartRate: Double
    let interrupted: SessionInterruptionReasonV1?
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!

func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

func frames(for seed: SeededSession, sessionID: UUID, createdAt: Date) -> [FootySessionFrameV1] {
    let endedAt = seed.startedAt.addingTimeInterval(TimeInterval(seed.durationMinutes * 60))

    var heartRates: [(Date, Double)] = []
    var distances: [(Date, Double)] = []
    for minute in 0...seed.durationMinutes {
        let timestamp = seed.startedAt.addingTimeInterval(TimeInterval(minute * 60))
        // A gentle warm-up, a mid-session peak around minute 34-37, then a
        // slight fade. Purely synthetic, deterministic.
        let phase = Double(minute) / Double(seed.durationMinutes)
        let peakBump = minute >= 34 && minute <= 37 ? 18.0 : 0.0
        let bpm = seed.averageHeartRate - 12.0 * (1 - phase) + 8.0 * phase + peakBump
        heartRates.append((timestamp, bpm))
        let meters = seed.distanceMeters * (minute == seed.durationMinutes ? 1.0 : Double(minute) / Double(seed.durationMinutes))
        distances.append((timestamp, meters))
    }

    var frames: [FootySessionFrameV1] = []
    let envelope = SessionEnvelopeV1(
        sessionID: sessionID,
        createdAt: createdAt,
        startedAt: seed.startedAt,
        captureSource: .batchedCoreMotion,
        initialAccelerometerAvailability: .available,
        initialDeviceMotionAvailability: .available
    )
    frames.append(FootySessionFrameV1(payload: .envelope(envelope)))

    for (timestamp, bpm) in heartRates {
        frames.append(
            FootySessionFrameV1(
                payload: .heartRateSnapshot(
                    HeartRateSnapshotV1(
                        timestamp: timestamp,
                        beatsPerMinute: SessionMetricV1(value: bpm, unit: .beatsPerMinute, provenance: .healthKitLive)
                    )
                )
            )
        )
    }
    for (timestamp, meters) in distances {
        frames.append(
            FootySessionFrameV1(
                payload: .distanceSnapshot(
                    DistanceSnapshotV1(
                        timestamp: timestamp,
                        meters: SessionMetricV1(value: meters, unit: .meters, provenance: .healthKitLive)
                    )
                )
            )
        )
    }

    let diagnostics = CaptureDiagnosticsV1(
        recordedAt: endedAt,
        source: .batchedCoreMotion,
        accelerometerAvailability: .available,
        deviceMotionAvailability: .available,
        accelerometerSampleCount: seed.durationMinutes * 60 * 50,
        deviceMotionSampleCount: seed.durationMinutes * 60 * 50,
        accelerometerReportedHz: 50,
        deviceMotionReportedHz: 50,
        maximumObservedGap: 1.2
    )
    frames.append(FootySessionFrameV1(payload: .captureDiagnostics(diagnostics)))

    let lifecycle: SessionLifecycleV1
    if let interrupted = seed.interrupted {
        lifecycle = .interrupted(reason: interrupted)
    } else {
        lifecycle = .completed
    }
    let summary = SessionSummaryMetricsV1(
        duration: SessionMetricV1(value: Double(seed.durationMinutes * 60), unit: .seconds, provenance: .healthKitFinalWorkout),
        distance: seed.distanceMeters > 0
            ? SessionMetricV1(value: seed.distanceMeters, unit: .meters, provenance: .healthKitFinalWorkout)
            : nil,
        averageHeartRate: seed.averageHeartRate > 0
            ? SessionMetricV1(value: seed.averageHeartRate, unit: .beatsPerMinute, provenance: .healthKitFinalWorkout)
            : nil,
        activeEnergy: SessionMetricV1(value: Double(seed.durationMinutes) * 11.0, unit: .kilocalories, provenance: .healthKitFinalWorkout)
    )
    let completion = SessionCompletionV1(
        endedAt: endedAt,
        lifecycle: lifecycle,
        summary: summary,
        healthKitSaveOutcome: .saved(workoutUUID: UUID())
    )
    frames.append(FootySessionFrameV1(payload: .completion(completion)))
    return frames
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: seed-simulator-vault <vaultRoot>\n".data(using: .utf8)!)
    exit(2)
}
let vaultRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
let packagesDirectory = vaultRoot.appendingPathComponent("Packages", isDirectory: true)
try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)

let seeds: [(SeededSession, SessionInterruptionReasonV1?)] = [
    (SeededSession(startedAt: makeDate(2025, 4, 12, 9, 14), durationMinutes: 72, distanceMeters: 8_400, averageHeartRate: 142, interrupted: nil), nil),
    (SeededSession(startedAt: makeDate(2025, 4, 8, 18, 37), durationMinutes: 64, distanceMeters: 7_100, averageHeartRate: 138, interrupted: nil), nil),
    (SeededSession(startedAt: makeDate(2025, 4, 5, 10, 5), durationMinutes: 38, distanceMeters: 3_900, averageHeartRate: 147, interrupted: .workoutEndedUnexpectedly), .workoutEndedUnexpectedly),
    (SeededSession(startedAt: makeDate(2025, 3, 29, 9, 2), durationMinutes: 68, distanceMeters: 8_000, averageHeartRate: 145, interrupted: nil), nil),
]

for (index, pair) in seeds.enumerated() {
    let (seed, interruption) = pair
    let sessionID = UUID()
    let createdAt = seed.startedAt.addingTimeInterval(-120)
    let frameList = frames(for: seed, sessionID: sessionID, createdAt: createdAt)
    let sessionDirectory = packagesDirectory.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)

    let temporaryURL = sessionDirectory.appendingPathComponent("seed-\(index).footysession")
    try FootySessionPackageV1.writePackage(frames: frameList, to: temporaryURL)
    let inspected = try SessionTransferCodecV1.inspectCompletePackage(at: temporaryURL)
    let digestHex = inspected.transferEnvelope.packageDigest.hexString
    let finalURL = sessionDirectory.appendingPathComponent("\(digestHex).footysession")
    if FileManager.default.fileExists(atPath: finalURL.path) {
        try FileManager.default.removeItem(at: finalURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

    let metadataURL = finalURL.appendingPathExtension("transfer-envelope.plist")
    let metadata = try SessionTransferCodecV1.encodeTransferEnvelope(inspected.transferEnvelope)
    try metadata.write(to: metadataURL)

    let state = interruption != nil ? "interrupted" : "completed"
    print("seeded \(state) session \(sessionID.uuidString.lowercased()) digest \(digestHex.prefix(12))… (\(inspected.transferEnvelope.byteCount) bytes)")
}
print("vault ready at \(packagesDirectory.path)")
