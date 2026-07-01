//
//  SyncClock.swift
//  HaptiScale
//
//  Time-base utilities. Core Haptics, the audio render thread and Core Motion each
//  timestamp against different but relatable clocks. We anchor everything to
//  `mach_absolute_time` (host time) and recover the *actual* speaker→mic lag by
//  cross-correlating the recorded signal against the emitted reference — mandatory,
//  because haptic and audio start latencies are independent and uncertain (§2).
//

import Foundation
import QuartzCore
import Accelerate

enum SyncClock {

    /// Current host time in seconds (monotonic).
    static func now() -> TimeInterval {
        CACurrentMediaTime()
    }

    /// Converts a mach host-time tick count to seconds.
    static func seconds(fromHostTime hostTime: UInt64) -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanos = Double(hostTime) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000.0
    }

    /// Finds the integer sample lag that best aligns `signal` to `reference` by
    /// full cross-correlation, searching only up to `maxLag` samples (the plausible
    /// speaker→mic + processing latency window). Returns the lag in samples and the
    /// normalized correlation peak (0...1) as a confidence.
    ///
    /// A positive lag means `signal` is delayed relative to `reference`.
    static func alignmentLag(signal: [Float],
                             reference: [Float],
                             maxLag: Int) -> (lag: Int, peak: Double) {
        guard !signal.isEmpty, !reference.isEmpty else { return (0, 0) }

        let refEnergy = sqrt(vDSP.sum(vDSP.multiply(reference, reference)))
        guard refEnergy > 0 else { return (0, 0) }

        var bestLag = 0
        var bestScore = -Double.greatestFiniteMagnitude
        let refLen = reference.count

        for lag in 0...maxLag {
            guard lag + refLen <= signal.count else { break }
            var dot: Float = 0
            var segEnergy: Float = 0
            signal.withUnsafeBufferPointer { sig in
                reference.withUnsafeBufferPointer { ref in
                    // dot product of reference with the lagged signal segment
                    vDSP_dotpr(ref.baseAddress!, 1,
                               sig.baseAddress! + lag, 1, &dot, vDSP_Length(refLen))
                    vDSP_svesq(sig.baseAddress! + lag, 1, &segEnergy, vDSP_Length(refLen))
                }
            }
            let denom = Double(refEnergy) * sqrt(Double(segEnergy))
            let score = denom > 0 ? Double(dot) / denom : 0
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        return (bestLag, max(0, min(1, bestScore)))
    }
}
