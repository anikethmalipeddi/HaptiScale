//
//  ExcitationController.swift
//  HaptiScale
//
//  Fires the synchronized excitation: a Core Haptics continuous swept-sine (sharpness
//  0→1 ≈ 80→230 Hz, dwelling near the LRA resonance ~0.73) together with the inaudible
//  18–22 kHz FMCW chirp on the speaker. Both are launched from the same dispatch so
//  their host-time offset is small and bounded; the exact residual lag is recovered
//  later by cross-correlation. See §2 (excitation strategy).
//

import Foundation
import CoreHaptics

final class ExcitationController {

    private var hapticEngine: CHHapticEngine?
    private var supportsHaptics = false
    private unowned let audio: AudioCapture
    private var chirp: [Float] = []

    init(audio: AudioCapture) {
        self.audio = audio
    }

    /// Prepares the haptic engine and caches the chirp at the actual sample rate.
    func configure() {
        chirp = SignalGeneration.standardChirp(sampleRate: audio.sampleRate)

        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = false      // keep alive across a measurement
            engine.stoppedHandler = { _ in }
            engine.resetHandler = { [weak self] in
                try? self?.hapticEngine?.start()
            }
            try engine.start()
            hapticEngine = engine
        } catch {
            supportsHaptics = false
        }
    }

    /// Emits one excitation burst: chirp + haptic sweep, launched together.
    /// The haptic runs only if hardware supports it; the acoustic channel always runs.
    func fireBurst() {
        // Launch acoustic and haptic as close together as possible.
        audio.playChirp(chirp)
        guard supportsHaptics, let engine = hapticEngine else { return }
        do {
            let pattern = try makeSweepPattern()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Non-fatal: fall back to acoustic-only for this burst.
        }
    }

    func stop() {
        hapticEngine?.stop(completionHandler: nil)
    }

    // MARK: - Haptic pattern

    /// A continuous haptic event whose `sharpness` sweeps 0→1 (mechanical chirp),
    /// dwelling near resonance, at full intensity for maximum SNR.
    private func makeSweepPattern() throws -> CHHapticPattern {
        let d = Config.hapticSweepDuration

        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Config.hapticSharpnessStart)
            ],
            relativeTime: 0,
            duration: d)

        // Sweep sharpness with extra dwell near the LRA resonance (~0.73).
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0.0,        value: Config.hapticSharpnessStart),
                .init(relativeTime: d * 0.40,   value: Config.hapticResonanceSharpness),
                .init(relativeTime: d * 0.60,   value: Config.hapticResonanceSharpness),
                .init(relativeTime: d,          value: Config.hapticSharpnessEnd)
            ],
            relativeTime: 0)

        return try CHHapticPattern(events: [event], parameterCurves: [sharpnessCurve])
    }
}
