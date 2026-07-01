//
//  TransferFunction.swift
//  HaptiScale
//
//  H1 transfer-function estimator and magnitude-squared coherence via Welch's
//  method (averaged cross/auto spectra). This is the single most informative
//  feature family per the Kirchhoff–Love analysis (§2, §4). Coherence gates burst
//  validity: low coherence in the excitation band = ambient noise / bad coupling.
//

import Foundation
import Accelerate

struct TransferFunctionResult {
    /// Frequency of each bin (Hz).
    let frequencies: [Double]
    /// |H1(f)| magnitude, output(y) relative to reference(x).
    let magnitude: [Double]
    /// Phase of H1(f) in radians.
    let phase: [Double]
    /// Magnitude-squared coherence γ²(f) in [0, 1].
    let coherence: [Double]
}

enum TransferFunction {

    /// Estimates H1 = Sxy / Sxx and coherence = |Sxy|² / (Sxx·Syy) over overlapping
    /// Hann-windowed segments.
    ///
    /// - Parameters:
    ///   - x: reference (emitted) signal.
    ///   - y: measured (recorded) signal, already time-aligned to `x`.
    ///   - sampleRate: samples per second.
    static func estimate(x: [Float],
                         y: [Float],
                         sampleRate: Double,
                         segment: Int = Config.welchSegment,
                         overlap: Int = Config.welchOverlap) -> TransferFunctionResult {
        let n = min(x.count, y.count)
        let half = segment / 2
        guard n >= segment else {
            return TransferFunctionResult(frequencies: [], magnitude: [], phase: [], coherence: [])
        }

        let fft = FFTProcessor(length: segment)
        let step = max(1, segment - overlap)

        // Accumulators for the averaged spectra.
        var sxxR = [Double](repeating: 0, count: half)   // auto-spectrum of x (real)
        var syyR = [Double](repeating: 0, count: half)   // auto-spectrum of y (real)
        var sxyR = [Double](repeating: 0, count: half)   // cross-spectrum real part
        var sxyI = [Double](repeating: 0, count: half)   // cross-spectrum imag part
        var segments = 0

        var start = 0
        while start + segment <= n {
            let xs = Array(x[start..<start + segment])
            let ys = Array(y[start..<start + segment])
            let winX = applyHann(xs)
            let winY = applyHann(ys)
            let X = fft.forwardSplit(winX)
            let Y = fft.forwardSplit(winY)

            for k in 0..<half {
                let xr = Double(X.real[k]), xi = Double(X.imag[k])
                let yr = Double(Y.real[k]), yi = Double(Y.imag[k])
                sxxR[k] += xr * xr + xi * xi
                syyR[k] += yr * yr + yi * yi
                // Sxy = conj(X) * Y
                sxyR[k] += xr * yr + xi * yi
                sxyI[k] += xr * yi - xi * yr
            }
            segments += 1
            start += step
        }

        guard segments > 0 else {
            return TransferFunctionResult(frequencies: [], magnitude: [], phase: [], coherence: [])
        }

        var freqs = [Double](repeating: 0, count: half)
        var mag = [Double](repeating: 0, count: half)
        var phase = [Double](repeating: 0, count: half)
        var coh = [Double](repeating: 0, count: half)
        let eps = 1e-12

        for k in 0..<half {
            freqs[k] = Double(k) * sampleRate / Double(segment)
            let sxyMagSq = sxyR[k] * sxyR[k] + sxyI[k] * sxyI[k]
            // H1 = Sxy / Sxx
            mag[k] = sqrt(sxyMagSq) / (sxxR[k] + eps)
            phase[k] = atan2(sxyI[k], sxyR[k])
            // γ² = |Sxy|² / (Sxx · Syy)
            coh[k] = sxyMagSq / (sxxR[k] * syyR[k] + eps)
            coh[k] = min(1.0, max(0.0, coh[k]))
        }

        return TransferFunctionResult(frequencies: freqs, magnitude: mag, phase: phase, coherence: coh)
    }

    /// Mean coherence within a frequency band — the burst-validity metric.
    static func meanCoherence(_ result: TransferFunctionResult,
                              band: ClosedRange<Double>) -> Double {
        var sum = 0.0
        var count = 0
        for (i, f) in result.frequencies.enumerated() where band.contains(f) {
            sum += result.coherence[i]
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func applyHann(_ x: [Float]) -> [Float] {
        var w = [Float](repeating: 0, count: x.count)
        vDSP_hann_window(&w, vDSP_Length(x.count), Int32(vDSP_HANN_NORM))
        return vDSP.multiply(x, w)
    }
}
