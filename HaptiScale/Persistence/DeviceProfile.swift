//
//  DeviceProfile.swift
//  HaptiScale
//
//  Per-device-model fingerprint + persisted calibration. Every relevant paper
//  states each phone *model* needs its own damping/force profile (§6). We capture a
//  rigid, no-load fingerprint at first launch (tare resonance / Q / τ) to select
//  per-model normalizers, and store optional user calibration samples for the
//  calibration-based estimator. Fully offline JSON in Application Support.
//

import Foundation

/// A labeled calibration observation: a known reference mass and the tare-delta
/// feature values measured for it. Used to fit the fallback mass curve.
struct CalibrationSample: Codable, Identifiable {
    var id = UUID()
    let grams: Double
    let features: FeatureVector
    let bowlID: String?
    let date: Date
}

struct DeviceProfile: Codable {
    var hardwareModel: String            // e.g. "iPhone14,2"
    var marketingName: String            // best-effort human name

    // First-launch rigid-surface, no-load fingerprint.
    var tareResonanceHz: Double = 0
    var tareQ: Double = 0
    var tareTau: Double = 0
    var isProfiled: Bool = false

    // User-provided reference weighings (optional "improve accuracy" flow).
    var calibrationSamples: [CalibrationSample] = []

    var updated: Date = Date()

    static func current() -> DeviceProfile {
        let model = DeviceProfile.hardwareIdentifier()
        return DeviceProfile(hardwareModel: model,
                             marketingName: DeviceProfile.marketingName(for: model))
    }

    /// Raw hardware identifier via uname (e.g. "iPhone15,2").
    static func hardwareIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.reduce(into: "") { acc, elem in
            if let v = elem.value as? Int8, v != 0 {
                acc.append(Character(UnicodeScalar(UInt8(v))))
            }
        }
        return id.isEmpty ? "unknown" : id
    }

    /// Small lookup for the iPhone 12–15 family the app targets; falls back to the
    /// raw identifier so unknown devices still get a distinct profile.
    static func marketingName(for id: String) -> String {
        let map: [String: String] = [
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max"
        ]
        return map[id] ?? id
    }
}

/// JSON-backed store for the device profile.
final class ProfileStore {
    static let shared = ProfileStore()
    private let url: URL
    private(set) var profile: DeviceProfile

    private init() {
        let dir = ProfileStore.supportDirectory()
        url = dir.appendingPathComponent("device_profile.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(DeviceProfile.self, from: data) {
            profile = decoded
        } else {
            profile = DeviceProfile.current()
        }
    }

    func save() {
        profile.updated = Date()
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func update(_ mutate: (inout DeviceProfile) -> Void) {
        mutate(&profile)
        save()
    }

    static func supportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("HaptiScale", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
