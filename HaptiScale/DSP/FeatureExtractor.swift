//
//  FeatureExtractor.swift
//  HaptiScale
//
//  Turns a set of coherently-averaged excitation bursts into the feature vector the
//  mass estimator consumes. Implements the §4 feature families:
//   • Microphone: H1 transfer function + coherence, matched-filter impulse response,
//     ring-down τ, resonance/Q in the structure-borne band, MFCCs, spectral centroid.
//   • IMU: band RMS energies, Z:(X,Y) asymmetry, coarse resonance, envelope τ.
//  Coherent averaging across N bursts cuts uncorrelated noise by √N (§2).
//

import Foundation
import Accelerate

struct ExtractionOutput {
    let features: FeatureVector
    let meanCoherence: Double
    let impulseResponse: [Float]   // for the debug spectrum view
    let audioSpectrum: [Float]
    let imuSpectrum: [Float]
    let tiltDegrees: Double
    let axisAsymmetry: Double
    let nonExcitationEnergyRatio: Double
    let recaptureLevel: Double     // emitted-signal recapture (occlusion check)
}

final class FeatureExtractor {

    static let structureBorneBand: ClosedRange<Double> = Config.chirpStartHz...Config.chirpEndHz
    static let hapticBand: ClosedRange<Double> = 80...230

    private let mfcc: MFCC
    private let sampleRate: Double
    private let fft: FFTProcessor

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.mfcc = MFCC(sampleRate: sampleRate, filterCount: 26, coefficientCount: 13)
        self.fft = FFTProcessor(length: Config.fftLength)
    }

    /// Extracts features from the bursts of one measurement.
    func extract(bursts: [RawCapture]) -> ExtractionOutput {
        precondition(!bursts.isEmpty)
        let reference = bursts[0].reference
        let maxLag = Int(0.06 * sampleRate)     // plausible speaker→mic + IO latency

        // --- Coherently average the aligned audio across bursts ---
        let windowLen = reference.count + Int(0.15 * sampleRate)   // chirp + ring-down tail
        var averaged = [Float](repeating: 0, count: windowLen)
        var coherenceAccum = 0.0
        var used = 0
        var recaptureAccum = 0.0

        for burst in bursts {
            let (lag, peak) = SyncClock.alignmentLag(signal: burst.audio,
                                                     reference: reference,
                                                     maxLag: maxLag)
            recaptureAccum += peak
            guard lag + windowLen <= burst.audio.count else { continue }
            for i in 0..<windowLen { averaged[i] += burst.audio[lag + i] }
            used += 1
        }
        if used > 0 {
            var inv = Float(1.0 / Double(used))
            vDSP_vsmul(averaged, 1, &inv, &averaged, 1, vDSP_Length(windowLen))
        }
        let recaptureLevel = bursts.isEmpty ? 0 : recaptureAccum / Double(bursts.count)

        var features = FeatureVector()

        // --- Transfer function + coherence (mic vs reference) ---
        let tf = TransferFunction.estimate(x: reference, y: Array(averaged.prefix(reference.count)),
                                           sampleRate: sampleRate)
        let meanCoh = TransferFunction.meanCoherence(tf, band: Self.structureBorneBand)
        coherenceAccum = meanCoh
        addTransferFunctionFeatures(tf, into: &features)

        // --- Matched-filter impulse response (pulse compression) ---
        let matched = SignalGeneration.matchedFilter(for: reference)
        let ir = convolve(averaged, matched)
        let tau = EnvelopeAnalysis.decayTau(ir, sampleRate: sampleRate)
        features.set("mic_ir_tau", tau)
        features.set("mic_ir_peak", Double(ir.map(abs).max() ?? 0))

        // MFCCs of a frame centered on the impulse-response peak.
        let mfccVec = mfcc.compute(centeredFrame(ir, length: Config.fftLength))
        for (i, c) in mfccVec.enumerated() { features.set("mic_mfcc_\(i)", c) }

        // --- Audio magnitude spectrum + structure-borne resonance ---
        let audioSpec = fft.magnitudeSpectrum(Array(averaged.prefix(Config.fftLength)))
        addSpectralFeatures(audioSpec, prefix: "mic", band: Self.structureBorneBand, into: &features)
        if let peak = EnvelopeAnalysis.resonance(magnitude: audioSpec, sampleRate: sampleRate,
                                                 fftLength: Config.fftLength,
                                                 band: Self.structureBorneBand) {
            features.set("mic_res_f", peak.frequency)
            features.set("mic_res_q", peak.q)
            features.set("mic_res_amp", peak.amplitude)
            features.set("mic_res_bw", peak.bandwidth)
        }

        // Fraction of energy outside the excitation band = ambient noise indicator.
        let nonExc = nonExcitationEnergyRatio(audioSpec)

        // --- IMU features ---
        let imuAll = bursts.flatMap { $0.imu }
        let (imuSpec, tilt, asym) = addIMUFeatures(imuAll, into: &features)

        // --- Environment covariates (mandatory) ---
        let env = bursts[0].env
        features.set("battery", env.batteryLevel)
        features.set("thermal", Double(env.thermalState))

        return ExtractionOutput(features: features,
                                meanCoherence: coherenceAccum,
                                impulseResponse: ir,
                                audioSpectrum: audioSpec,
                                imuSpectrum: imuSpec,
                                tiltDegrees: tilt,
                                axisAsymmetry: asym,
                                nonExcitationEnergyRatio: nonExc,
                                recaptureLevel: recaptureLevel)
    }

    // MARK: - Feature helpers

    private func addTransferFunctionFeatures(_ tf: TransferFunctionResult,
                                             into features: inout FeatureVector) {
        guard !tf.frequencies.isEmpty else { return }
        // Sample |H1| at a set of anchor frequencies across the structure-borne band.
        let anchors = stride(from: Self.structureBorneBand.lowerBound,
                             through: Self.structureBorneBand.upperBound,
                             by: 500.0)
        for f in anchors {
            let idx = nearestIndex(tf.frequencies, to: f)
            features.set("mic_H_\(Int(f))", tf.magnitude[idx])
            features.set("mic_coh_\(Int(f))", tf.coherence[idx])
        }
        // Band-aggregate magnitude stats.
        var mags = [Double]()
        for (i, f) in tf.frequencies.enumerated() where Self.structureBorneBand.contains(f) {
            mags.append(tf.magnitude[i])
        }
        if !mags.isEmpty {
            features.set("mic_H_mean", mags.reduce(0, +) / Double(mags.count))
            features.set("mic_H_max", mags.max() ?? 0)
        }
    }

    private func addSpectralFeatures(_ spectrum: [Float], prefix: String,
                                     band: ClosedRange<Double>, into features: inout FeatureVector) {
        let binHz = sampleRate / Double(Config.fftLength)
        var weighted = 0.0, total = 0.0
        for b in 0..<spectrum.count {
            let f = Double(b) * binHz
            guard band.contains(f) else { continue }
            let m = Double(spectrum[b])
            weighted += f * m
            total += m
        }
        let centroid = total > 0 ? weighted / total : 0
        features.set("\(prefix)_centroid", centroid)
        features.set("\(prefix)_band_energy", total)
    }

    /// Coarse IMU spectral + spatial features. IMU aliases the Taptic band (100 Hz
    /// cap), so treated as corroborating: RMS energies, Z:(X,Y) asymmetry, tilt.
    private func addIMUFeatures(_ imu: [IMUSample],
                               into features: inout FeatureVector) -> (spectrum: [Float], tilt: Double, asymmetry: Double) {
        guard imu.count > 4 else { return ([], 0, 0) }

        let ax = imu.map { Float($0.ax) }
        let ay = imu.map { Float($0.ay) }
        let az = imu.map { Float($0.az) }

        let rmsX = rms(ax), rmsY = rms(ay), rmsZ = rms(az)
        features.set("imu_rms_x", Double(rmsX))
        features.set("imu_rms_y", Double(rmsY))
        features.set("imu_rms_z", Double(rmsZ))
        let lateral = Double(rmsX + rmsY)
        features.set("imu_z_lateral_ratio", lateral > 0 ? Double(rmsZ) / lateral : 0)

        // Axis asymmetry (centering indicator).
        let asym = (Double(rmsX) + Double(rmsY)) > 0
            ? abs(Double(rmsX) - Double(rmsY)) / (Double(rmsX) + Double(rmsY)) : 0
        features.set("imu_axis_asymmetry", asym)

        // Envelope τ of Z-axis (corroborating damping signal).
        features.set("imu_z_tau", EnvelopeAnalysis.decayTau(az, sampleRate: 100.0))

        // Coarse zero-padded FFT of Z for a spectral-peak feature.
        let padded = zeroPad(az, to: 256)
        let coarse = FFTProcessor(length: 256)
        let spec = coarse.magnitudeSpectrum(padded)
        if let peak = spec.enumerated().max(by: { $0.element < $1.element }) {
            features.set("imu_z_peak_bin", Double(peak.offset))
            features.set("imu_z_peak_amp", Double(peak.element))
        }

        // Tilt from the mean gravity vector (flatness check).
        let gz = imu.map { $0.gravityZ }.reduce(0, +) / Double(imu.count)
        let tilt = acos(min(1, max(-1, abs(gz)))) * 180.0 / Double.pi
        features.set("imu_tilt_deg", tilt)

        return (spec, tilt, asym)
    }

    private func nonExcitationEnergyRatio(_ spectrum: [Float]) -> Double {
        let binHz = sampleRate / Double(Config.fftLength)
        var inBand = 0.0, outBand = 0.0
        for b in 1..<spectrum.count {
            let f = Double(b) * binHz
            let e = Double(spectrum[b]) * Double(spectrum[b])
            if Self.structureBorneBand.contains(f) || Self.hapticBand.contains(f) {
                inBand += e
            } else {
                outBand += e
            }
        }
        let total = inBand + outBand
        return total > 0 ? outBand / total : 0
    }

    // MARK: - Small numeric utilities

    private func convolve(_ signal: [Float], _ filter: [Float]) -> [Float] {
        let resultLen = signal.count - filter.count + 1
        guard resultLen > 0 else { return [] }
        var result = [Float](repeating: 0, count: resultLen)
        // vDSP_conv correlates; feed the (already reversed) matched filter.
        vDSP_conv(signal, 1, filter, 1, &result, 1, vDSP_Length(resultLen), vDSP_Length(filter.count))
        return result
    }

    private func centeredFrame(_ x: [Float], length: Int) -> [Float] {
        guard !x.isEmpty else { return [Float](repeating: 0, count: length) }
        let peakIdx = x.enumerated().max(by: { abs($0.element) < abs($1.element) })?.offset ?? 0
        var out = [Float](repeating: 0, count: length)
        let start = max(0, peakIdx - length / 4)
        for i in 0..<length where start + i < x.count { out[i] = x[start + i] }
        return out
    }

    private func rms(_ x: [Float]) -> Float {
        var mean: Float = 0
        vDSP_measqv(x, 1, &mean, vDSP_Length(x.count))
        return sqrt(mean)
    }

    private func zeroPad(_ x: [Float], to length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for i in 0..<min(length, x.count) { out[i] = x[i] }
        return out
    }

    private func nearestIndex(_ arr: [Double], to value: Double) -> Int {
        var best = 0
        var bestD = Double.greatestFiniteMagnitude
        for (i, v) in arr.enumerated() {
            let d = abs(v - value)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}
