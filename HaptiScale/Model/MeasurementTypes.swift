//
//  MeasurementTypes.swift
//  HaptiScale
//
//  Core value types passed between capture, DSP, the estimator and the UI.
//

import Foundation

/// One 100 Hz Core Motion sample (gravity-separated user acceleration + gyro).
struct IMUSample: Codable {
    let t: Double          // host time (s)
    let ax: Double         // userAcceleration, g
    let ay: Double
    let az: Double
    let gx: Double         // rotationRate, rad/s
    let gy: Double
    let gz: Double
    let gravityX: Double    // gravity vector, g (for tilt/flatness checks)
    let gravityY: Double
    let gravityZ: Double
}

/// Environmental covariates the blueprint flags as mandatory model features.
struct EnvironmentContext: Codable {
    var batteryLevel: Double        // 0...1, −1 if unknown
    var thermalState: Int           // ProcessInfo.ThermalState.rawValue
    var timestamp: Date

    static func capture() -> EnvironmentContext {
        EnvironmentContext(batteryLevel: BatteryMonitor.level(),
                           thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                           timestamp: Date())
    }
}

/// Everything recorded during a single excitation burst plus the reference used
/// to emit it. This is the atom the FeatureExtractor consumes and the DataLogger
/// persists for training.
struct RawCapture {
    let audio: [Float]              // recorded mic samples
    let reference: [Float]          // emitted FMCW reference (same sample rate)
    let sampleRate: Double
    let imu: [IMUSample]
    let env: EnvironmentContext
    let burstIndex: Int
}

/// Quality classification surfaced to the user; we refuse to show a number on red.
enum SetupQuality: String, Codable {
    case good        // green
    case marginal    // amber
    case bad         // red

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .marginal: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        }
    }
}

/// A single validation issue detected during setup checks.
struct SetupIssue: Identifiable, Codable {
    var id: String { code }
    let code: String
    let message: String
    let severity: SetupQuality
}

/// Final result of a measurement.
struct MeasurementResult {
    let grams: Double
    let ciLow: Double
    let ciHigh: Double
    let quality: SetupQuality
    let issues: [SetupIssue]
    let coherence: Double
    let features: FeatureVector
    let bowlID: String?
    let env: EnvironmentContext

    /// Half-width of the confidence interval for display ("182 g ± 12 g").
    var ciHalfWidth: Double { (ciHigh - ciLow) / 2.0 }
}

/// Reads the battery level, enabling monitoring lazily.
enum BatteryMonitor {
    private static var enabled = false
    static func level() -> Double {
        #if canImport(UIKit)
        if !enabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
            enabled = true
        }
        let l = Double(UIDevice.current.batteryLevel)
        return l < 0 ? -1 : l
        #else
        return -1
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
