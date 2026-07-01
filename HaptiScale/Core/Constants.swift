//
//  Constants.swift
//  HaptiScale
//
//  Central tuning constants for excitation, capture and DSP. These are the knobs
//  the blueprint calls out as physically important; keep them in one place so a
//  device profile or A/B experiment can override them cleanly.
//

import Foundation

enum Config {

    // MARK: Audio

    /// Requested capture/playback sample rate. iOS treats this as a hint; always
    /// read back `AVAudioSession.sampleRate` after activation and adapt.
    static let preferredSampleRate: Double = 48_000

    /// Small IO buffer for low-latency render/capture (hint only).
    static let preferredIOBufferDuration: TimeInterval = 0.005

    // MARK: Acoustic FMCW chirp (structure-borne channel)

    /// Inaudible FMCW band. Above hearing, below the ~23 kHz mic roll-off.
    static let chirpStartHz: Double = 18_000
    static let chirpEndHz: Double = 22_000

    /// Duration of a single up-chirp.
    static let chirpDuration: TimeInterval = 0.20

    /// Linear amplitude of the emitted chirp (0...1). High for SNR but leaves
    /// headroom to avoid speaker clipping / intermodulation into the audible band.
    static let chirpAmplitude: Float = 0.85

    // MARK: Haptic swept sine (mechanical channel)

    /// Core Haptics `sharpness` sweep bounds. On measured hardware sharpness maps
    /// roughly 0.0 -> ~80 Hz, 1.0 -> ~230 Hz of LRA drive frequency. Re-measured
    /// per phone model during profiling; these are only the sweep endpoints.
    static let hapticSharpnessStart: Float = 0.0
    static let hapticSharpnessEnd: Float = 1.0

    /// Extra dwell near the LRA resonance / peak acceleration (sharpness ~0.73).
    static let hapticResonanceSharpness: Float = 0.73

    /// Duration of one haptic sweep burst.
    static let hapticSweepDuration: TimeInterval = 0.30

    // MARK: Measurement

    /// Number of excitation bursts averaged coherently per measurement.
    /// 3 = fast / lower accuracy, 8–10 = best accuracy (blueprint §7).
    static let burstsPerMeasurement = 6

    /// Gap between bursts to let transients die out.
    static let interBurstGap: TimeInterval = 0.12

    /// Zero-load tare baseline duration (à la VibroScale's 3 s "WAIT").
    static let tareDuration: TimeInterval = 3.0

    // MARK: DSP

    /// FFT length used for spectral estimation. Power of two.
    static let fftLength = 4096

    /// Welch segment length / overlap for the H1 transfer-function estimator.
    static let welchSegment = 1024
    static let welchOverlap = 512

    /// Coherence below this in the excitation band means ambient noise / bad
    /// coupling — the burst is rejected (blueprint §8).
    static let minCoherence: Double = 0.6

    // MARK: Setup validation thresholds

    /// Max tilt from horizontal (degrees) before we consider the phone "not flat".
    static let maxTiltDegrees: Double = 6.0

    /// X-vs-Y RMS energy asymmetry above this suggests an off-center bowl.
    static let maxAxisAsymmetry: Double = 0.45
}
