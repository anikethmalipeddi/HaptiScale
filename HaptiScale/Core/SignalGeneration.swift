//
//  SignalGeneration.swift
//  HaptiScale
//
//  Generates the reference excitation waveforms. The FMCW chirp is emitted on the
//  speaker and — critically — kept as the software reference against which the
//  recorded microphone signal is cross-correlated and deconvolved. See §2 of the
//  blueprint (excitation strategy) and §4 (transfer-function features).
//

import Foundation
import Accelerate

enum SignalGeneration {

    /// A linear-frequency (FMCW) up-chirp x(t) = sin(2π(f0·t + (k/2)·t²)),
    /// windowed with a short raised-cosine taper to suppress spectral splatter at
    /// the edges. Returned at the given sample rate.
    ///
    /// - Parameters:
    ///   - f0: start frequency in Hz.
    ///   - f1: end frequency in Hz.
    ///   - duration: chirp length in seconds.
    ///   - sampleRate: samples per second.
    ///   - amplitude: peak linear amplitude (0...1).
    static func linearChirp(f0: Double,
                            f1: Double,
                            duration: TimeInterval,
                            sampleRate: Double,
                            amplitude: Float) -> [Float] {
        let n = max(1, Int((duration * sampleRate).rounded()))
        let k = (f1 - f0) / duration            // sweep rate, Hz/s
        var out = [Float](repeating: 0, count: n)

        for i in 0..<n {
            let t = Double(i) / sampleRate
            let phase = 2.0 * Double.pi * (f0 * t + 0.5 * k * t * t)
            out[i] = amplitude * Float(sin(phase))
        }

        applyRaisedCosineTaper(&out, taperFraction: 0.08)
        return out
    }

    /// The standard app chirp: an inaudible 18→22 kHz FMCW pulse.
    static func standardChirp(sampleRate: Double) -> [Float] {
        linearChirp(f0: Config.chirpStartHz,
                    f1: Config.chirpEndHz,
                    duration: Config.chirpDuration,
                    sampleRate: sampleRate,
                    amplitude: Config.chirpAmplitude)
    }

    /// Applies a symmetric raised-cosine (Tukey) taper in place so the emitted
    /// pulse starts and ends at zero — avoids clicks and out-of-band splatter.
    static func applyRaisedCosineTaper(_ x: inout [Float], taperFraction: Double) {
        let n = x.count
        guard n > 4 else { return }
        let taper = max(1, Int(Double(n) * taperFraction))
        for i in 0..<taper {
            let w = Float(0.5 * (1.0 - cos(Double.pi * Double(i) / Double(taper))))
            x[i] *= w
            x[n - 1 - i] *= w
        }
    }

    /// Builds the reference matched filter for deconvolution: the time-reversed
    /// chirp. Convolving the recording with this gives the compressed impulse
    /// response of the coupled system (pulse-compression / matched filtering).
    static func matchedFilter(for reference: [Float]) -> [Float] {
        Array(reference.reversed())
    }
}
