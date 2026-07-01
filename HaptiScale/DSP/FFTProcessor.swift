//
//  FFTProcessor.swift
//  HaptiScale
//
//  Thin wrapper over vDSP's real FFT. Reusable setup, Hann windowing, magnitude and
//  power spectra. Everything downstream (transfer function, MFCC, resonance/Q) is
//  built on this. All work happens off the audio thread on a utility queue (§9).
//

import Foundation
import Accelerate

/// Real-input FFT of a fixed power-of-two length.
final class FFTProcessor {

    let length: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    init(length: Int) {
        precondition(length > 0 && (length & (length - 1)) == 0, "FFT length must be a power of two")
        self.length = length
        self.log2n = vDSP_Length(log2(Double(length)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // Precompute a Hann window once.
        var w = [Float](repeating: 0, count: length)
        vDSP_hann_window(&w, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        self.window = w
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Applies the Hann window to (a zero-padded copy of) the input.
    private func windowed(_ input: [Float]) -> [Float] {
        var buf = [Float](repeating: 0, count: length)
        let n = min(input.count, length)
        for i in 0..<n { buf[i] = input[i] }
        vDSP.multiply(buf, window, result: &buf)
        return buf
    }

    /// One-sided magnitude spectrum (length/2 bins) of a windowed real signal.
    func magnitudeSpectrum(_ input: [Float]) -> [Float] {
        let complex = forwardSplit(windowed(input))
        var mags = [Float](repeating: 0, count: length / 2)
        complex.real.withUnsafeBufferPointer { realPtr in
            complex.imag.withUnsafeBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: realPtr.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: imagPtr.baseAddress!))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(length / 2))
            }
        }
        return mags
    }

    /// One-sided power spectrum (magnitude squared).
    func powerSpectrum(_ input: [Float]) -> [Float] {
        let m = magnitudeSpectrum(input)
        return vDSP.multiply(m, m)
    }

    /// Forward real FFT returning split-complex real/imag arrays of length/2.
    /// Uses the standard vDSP packed real-FFT convention.
    func forwardSplit(_ windowedInput: [Float]) -> (real: [Float], imag: [Float]) {
        let half = length / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)

        windowedInput.withUnsafeBufferPointer { inPtr in
            inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typedPtr in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        // Pack the real input into split-complex form.
                        vDSP_ctoz(typedPtr, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // vDSP scales the forward transform by 2; correct it.
                        var scale: Float = 0.5
                        vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(half))
                        vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }
        }
        return (realp, imagp)
    }

    /// Frequency (Hz) of a given bin index for the supplied sample rate.
    func frequency(forBin bin: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(length)
    }

    /// Bin index nearest to a given frequency.
    func bin(forFrequency hz: Double, sampleRate: Double) -> Int {
        Int((hz * Double(length) / sampleRate).rounded())
    }
}
