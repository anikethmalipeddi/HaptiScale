//
//  DataLogger.swift
//  HaptiScale
//
//  Persists raw measurements for offline model training (§10). For each labeled
//  measurement it writes: 32-bit float WAV (recorded audio), the emitted reference
//  WAV, an IMU CSV, and a JSON sidecar with all metadata (phone model + unit id,
//  bowl class + id, surface, food class, ground-truth grams, battery, thermal,
//  timestamps, app/OS version) plus the extracted feature vector. Files land in the
//  app's Documents dir so they're reachable via the Files app / iTunes file sharing.
//

import Foundation

struct MeasurementMetadata: Codable {
    var groundTruthGrams: Double?
    var bowlID: String?
    var bowlMaterial: String?
    var surface: String?
    var foodClass: String?
    var phoneModel: String
    var phoneUnitID: String
    var battery: Double
    var thermalState: Int
    var osVersion: String
    var appVersion: String
    var sampleRate: Double
    var burstCount: Int
    var timestamp: Date
    var features: FeatureVector
    var predictedGrams: Double?
    var quality: String
    var coherence: Double
}

final class DataLogger {
    static let shared = DataLogger()

    private let root: URL
    private let unitID: String

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("HaptiScaleData", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Stable per-install unit id (distinguishes physical units of a model).
        let key = "haptiscale.unitID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            unitID = existing
        } else {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            unitID = id
        }
    }

    var storageURL: URL { root }

    /// Count of saved measurement folders (for the Data tab).
    func savedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count) ?? 0
    }

    /// Writes a full measurement record. Returns the created folder URL.
    @discardableResult
    func save(bursts: [RawCapture],
              features: FeatureVector,
              prediction: MassPrediction?,
              result: MeasurementResult?,
              label: MeasurementLabel) -> URL? {
        guard let first = bursts.first else { return nil }
        let stamp = Self.folderFormatter.string(from: Date())
        let dir = root.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Concatenate audio + reference across bursts.
        let audio = bursts.flatMap { $0.audio }
        let reference = first.reference
        writeFloatWAV(audio, sampleRate: first.sampleRate, to: dir.appendingPathComponent("audio.wav"))
        writeFloatWAV(reference, sampleRate: first.sampleRate, to: dir.appendingPathComponent("reference.wav"))
        writeIMUCSV(bursts, to: dir.appendingPathComponent("imu.csv"))

        let meta = MeasurementMetadata(
            groundTruthGrams: label.groundTruthGrams,
            bowlID: label.bowlID,
            bowlMaterial: label.bowlMaterial,
            surface: label.surface,
            foodClass: label.foodClass,
            phoneModel: ProfileStore.shared.profile.hardwareModel,
            phoneUnitID: unitID,
            battery: first.env.batteryLevel,
            thermalState: first.env.thermalState,
            osVersion: Self.osVersion(),
            appVersion: Self.appVersion(),
            sampleRate: first.sampleRate,
            burstCount: bursts.count,
            timestamp: Date(),
            features: features,
            predictedGrams: prediction?.grams,
            quality: result?.quality.rawValue ?? "unknown",
            coherence: result?.coherence ?? 0)

        if let data = try? JSONEncoder.pretty.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("metadata.json"), options: .atomic)
        }
        return dir
    }

    // MARK: - Writers

    private func writeIMUCSV(_ bursts: [RawCapture], to url: URL) {
        var csv = "burst,t,ax,ay,az,gx,gy,gz,gravityX,gravityY,gravityZ\n"
        for b in bursts {
            for s in b.imu {
                csv += "\(b.burstIndex),\(s.t),\(s.ax),\(s.ay),\(s.az),\(s.gx),\(s.gy),\(s.gz),\(s.gravityX),\(s.gravityY),\(s.gravityZ)\n"
            }
        }
        try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Minimal 32-bit IEEE-float mono WAV writer.
    private func writeFloatWAV(_ samples: [Float], sampleRate: Double, to url: URL) {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let sr = UInt32(sampleRate)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = samples.count * MemoryLayout<Float>.size

        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF"); append32(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt "); append32(16)
        append16(3)                       // format = IEEE float
        append16(channels)
        append32(sr)
        append32(byteRate)
        append16(blockAlign)
        append16(bitsPerSample)
        append("data"); append32(UInt32(dataBytes))
        if dataBytes > 0 {
            samples.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                data.append(UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                                                count: dataBytes))
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// User-supplied labels attached at save time.
struct MeasurementLabel {
    var groundTruthGrams: Double?
    var bowlID: String?
    var bowlMaterial: String?
    var surface: String?
    var foodClass: String?
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
