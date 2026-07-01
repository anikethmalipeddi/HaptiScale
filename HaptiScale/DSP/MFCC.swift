//
//  MFCC.swift
//  HaptiScale
//
//  Mel-frequency cepstral coefficients of the coupled-system impulse response.
//  SoQr's proven feature for container/content acoustic response (§4, §11). Mel
//  filterbank over the power spectrum → log → DCT-II. We keep the low-order
//  coefficients (excluding c0 energy by default is optional here — we keep it).
//

import Foundation
import Accelerate

final class MFCC {

    let sampleRate: Double
    let fftLength: Int
    let filterCount: Int
    let coefficientCount: Int
    private let fft: FFTProcessor
    private let filterbank: [[Float]]   // [filterCount][fftLength/2]

    init(sampleRate: Double,
         fftLength: Int = Config.fftLength,
         filterCount: Int = 26,
         coefficientCount: Int = 13,
         lowHz: Double = 100,
         highHz: Double? = nil) {
        self.sampleRate = sampleRate
        self.fftLength = fftLength
        self.filterCount = filterCount
        self.coefficientCount = coefficientCount
        self.fft = FFTProcessor(length: fftLength)
        self.filterbank = MFCC.buildMelFilterbank(sampleRate: sampleRate,
                                                  fftLength: fftLength,
                                                  filterCount: filterCount,
                                                  lowHz: lowHz,
                                                  highHz: highHz ?? sampleRate / 2)
    }

    /// Computes the MFCC vector for a frame of samples.
    func compute(_ frame: [Float]) -> [Double] {
        let power = fft.powerSpectrum(frame)             // length/2 bins
        // Filterbank energies.
        var melEnergies = [Double](repeating: 0, count: filterCount)
        for m in 0..<filterCount {
            var acc: Float = 0
            vDSP_dotpr(filterbank[m], 1, power, 1, &acc, vDSP_Length(power.count))
            melEnergies[m] = Double(log(max(acc, 1e-10)))
        }
        // DCT-II → cepstral coefficients.
        return dctII(melEnergies, keep: coefficientCount)
    }

    // MARK: - Mel filterbank

    private static func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
    private static func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

    private static func buildMelFilterbank(sampleRate: Double,
                                           fftLength: Int,
                                           filterCount: Int,
                                           lowHz: Double,
                                           highHz: Double) -> [[Float]] {
        let bins = fftLength / 2
        let lowMel = hzToMel(lowHz)
        let highMel = hzToMel(highHz)
        // filterCount+2 equally spaced points in mel.
        var points = [Double](repeating: 0, count: filterCount + 2)
        for i in 0..<points.count {
            let mel = lowMel + (highMel - lowMel) * Double(i) / Double(filterCount + 1)
            points[i] = melToHz(mel)
        }
        // Convert to FFT bin indices.
        let binOf: (Double) -> Int = { hz in Int((hz * Double(fftLength) / sampleRate).rounded()) }
        let f = points.map { min(bins - 1, max(0, binOf($0))) }

        var bank = [[Float]](repeating: [Float](repeating: 0, count: bins), count: filterCount)
        for m in 1...filterCount {
            let left = f[m - 1], center = f[m], right = f[m + 1]
            if center > left {
                for k in left..<center {
                    bank[m - 1][k] = Float(Double(k - left) / Double(center - left))
                }
            }
            if right > center {
                for k in center..<right {
                    bank[m - 1][k] = Float(Double(right - k) / Double(right - center))
                }
            }
        }
        return bank
    }

    // MARK: - DCT

    private func dctII(_ input: [Double], keep: Int) -> [Double] {
        let n = input.count
        var out = [Double](repeating: 0, count: keep)
        for k in 0..<keep {
            var sum = 0.0
            for i in 0..<n {
                sum += input[i] * cos(Double.pi * Double(k) * (Double(i) + 0.5) / Double(n))
            }
            out[k] = sum
        }
        return out
    }
}
