//
//  EnvelopeAnalysis.swift
//  HaptiScale
//
//  Damping / ring-down (τ), resonance frequency, and Q. The decay-time and Q
//  features are often more mass-sensitive and noise-robust than the raw frequency
//  shift (§1). Envelope via the analytic signal (Hilbert transform); τ from a
//  log-linear fit of the decay; Q from the −3 dB resonance bandwidth.
//

import Foundation
import Accelerate

enum EnvelopeAnalysis {

    /// Amplitude envelope of a real signal via the analytic signal magnitude.
    /// Computes the Hilbert transform in the frequency domain (zero the negative
    /// frequencies, double the positive ones) and returns |analytic|.
    static func envelope(_ signal: [Float]) -> [Float] {
        let n = signal.count
        guard n > 1 else { return signal }

        // Next power of two for a full-length complex FFT.
        var len = 1
        while len < n { len <<= 1 }
        let log2n = vDSP_Length(log2(Double(len)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return signal }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: len)
        var imag = [Float](repeating: 0, count: len)
        for i in 0..<n { real[i] = signal[i] }

        return real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                // Forward complex FFT.
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // Build the analytic-signal multiplier: 1 at DC & Nyquist, 2 for
                // positive freqs, 0 for negative freqs.
                var h = [Float](repeating: 0, count: len)
                h[0] = 1
                if len % 2 == 0 {
                    h[len / 2] = 1
                    for i in 1..<(len / 2) { h[i] = 2 }
                } else {
                    for i in 1...(len / 2) { h[i] = 2 }
                }
                vDSP_vmul(rp.baseAddress!, 1, h, 1, rp.baseAddress!, 1, vDSP_Length(len))
                vDSP_vmul(ip.baseAddress!, 1, h, 1, ip.baseAddress!, 1, vDSP_Length(len))

                // Inverse FFT back to the (complex) analytic signal.
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                var scale = Float(1.0 / Double(len))
                vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(len))
                vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1, vDSP_Length(len))

                // Envelope = magnitude of the analytic signal.
                var env = [Float](repeating: 0, count: len)
                vDSP_zvabs(&split, 1, &env, 1, vDSP_Length(len))
                return Array(env[0..<n])
            }
        }
    }

    /// Fits an exponential decay e^(−t/τ) to the ring-down after the envelope peak.
    /// Returns τ in seconds (larger = less damping). Uses a robust log-linear least
    /// squares over the portion of the tail above a noise floor.
    static func decayTau(_ signal: [Float], sampleRate: Double) -> Double {
        let env = envelope(signal)
        guard env.count > 8 else { return 0 }

        // Start the fit just after the peak.
        guard let peakIdx = env.firstIndex(of: env.max() ?? 0) else { return 0 }
        let peak = env[peakIdx]
        guard peak > 0 else { return 0 }

        let floor = peak * 0.05      // fit down to 5% of peak
        var ts = [Double]()
        var lys = [Double]()
        var i = peakIdx
        while i < env.count {
            let v = env[i]
            if v <= floor { break }
            ts.append(Double(i - peakIdx) / sampleRate)
            lys.append(Double(log(v)))
            i += 1
        }
        guard ts.count >= 4 else { return 0 }

        // Least-squares slope of ln(env) vs t; τ = −1 / slope.
        let meanT = ts.reduce(0, +) / Double(ts.count)
        let meanY = lys.reduce(0, +) / Double(lys.count)
        var num = 0.0, den = 0.0
        for k in 0..<ts.count {
            num += (ts[k] - meanT) * (lys[k] - meanY)
            den += (ts[k] - meanT) * (ts[k] - meanT)
        }
        guard den > 0 else { return 0 }
        let slope = num / den
        guard slope < 0 else { return 0 }
        return -1.0 / slope
    }

    struct ResonancePeak {
        let frequency: Double
        let amplitude: Double
        let q: Double          // Q = f0 / bandwidth(-3 dB)
        let bandwidth: Double
    }

    /// Locates the dominant resonance within a band of a magnitude spectrum and
    /// estimates its Q from the −3 dB (half-power) bandwidth.
    static func resonance(magnitude: [Float],
                          sampleRate: Double,
                          fftLength: Int,
                          band: ClosedRange<Double>) -> ResonancePeak? {
        let binHz = sampleRate / Double(fftLength)
        let startBin = max(1, Int(band.lowerBound / binHz))
        let endBin = min(magnitude.count - 1, Int(band.upperBound / binHz))
        guard startBin < endBin else { return nil }

        // Peak bin in band.
        var peakBin = startBin
        var peakVal = magnitude[startBin]
        for b in startBin...endBin where magnitude[b] > peakVal {
            peakVal = magnitude[b]
            peakBin = b
        }
        guard peakVal > 0 else { return nil }

        // Parabolic interpolation around the peak for sub-bin frequency accuracy.
        let f0: Double
        if peakBin > 0 && peakBin < magnitude.count - 1 {
            let a = Double(magnitude[peakBin - 1])
            let b = Double(magnitude[peakBin])
            let c = Double(magnitude[peakBin + 1])
            let denom = (a - 2 * b + c)
            let delta = denom != 0 ? 0.5 * (a - c) / denom : 0
            f0 = (Double(peakBin) + delta) * binHz
        } else {
            f0 = Double(peakBin) * binHz
        }

        // −3 dB bandwidth: walk out until magnitude drops below peak/√2.
        let half = Double(peakVal) / sqrt(2.0)
        var lo = peakBin
        while lo > startBin && Double(magnitude[lo]) > half { lo -= 1 }
        var hi = peakBin
        while hi < endBin && Double(magnitude[hi]) > half { hi += 1 }
        let bandwidth = Double(hi - lo) * binHz
        let q = bandwidth > 0 ? f0 / bandwidth : 0

        return ResonancePeak(frequency: f0, amplitude: Double(peakVal), q: q, bandwidth: bandwidth)
    }
}
