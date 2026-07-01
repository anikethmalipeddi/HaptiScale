//
//  SetupValidator.swift
//  HaptiScale
//
//  Rejects/warns on the failure modes in §8: soft surface, off-center bowl, hand
//  contact, ambient vibration, port occlusion, phone not flat. Produces a quality
//  badge (green/amber/red) and human-readable issues. We refuse to show a number on
//  red. The whole point is that most reliability comes from setup rejection, not the
//  regressor.
//

import Foundation

enum SetupValidator {

    /// Evaluates one measurement's extraction output against the selected bowl.
    static func evaluate(_ output: ExtractionOutput,
                         bowl: BowlFingerprint?) -> (quality: SetupQuality, issues: [SetupIssue]) {
        var issues: [SetupIssue] = []

        // Phone not flat — gravity vector off vertical.
        if output.tiltDegrees > Config.maxTiltDegrees {
            issues.append(SetupIssue(
                code: "not_flat",
                message: String(format: "Phone is tilted %.0f° — lay it flat on a hard surface.", output.tiltDegrees),
                severity: .bad))
        }

        // Low coherence: ambient noise, hand contact, or poor coupling.
        if output.meanCoherence < Config.minCoherence * 0.6 {
            issues.append(SetupIssue(
                code: "low_coherence",
                message: "Vibration didn't couple cleanly — check for a hard surface and hands-off.",
                severity: .bad))
        } else if output.meanCoherence < Config.minCoherence {
            issues.append(SetupIssue(
                code: "marginal_coherence",
                message: "Coupling is weak — result may be less accurate.",
                severity: .marginal))
        }

        // Ambient vibration: energy outside the excitation bands.
        if output.nonExcitationEnergyRatio > 0.6 {
            issues.append(SetupIssue(
                code: "ambient",
                message: "Background vibration detected — move away from appliances and retry.",
                severity: .bad))
        } else if output.nonExcitationEnergyRatio > 0.4 {
            issues.append(SetupIssue(
                code: "ambient_marginal",
                message: "Some background noise — averaging more bursts would help.",
                severity: .marginal))
        }

        // Off-center bowl: X-vs-Y RMS asymmetry.
        if output.axisAsymmetry > Config.maxAxisAsymmetry {
            issues.append(SetupIssue(
                code: "off_center",
                message: "Bowl looks off-center — center it over the phone.",
                severity: .marginal))
        }

        // Port occlusion: emitted signal barely recaptured.
        if output.recaptureLevel < 0.15 {
            issues.append(SetupIssue(
                code: "occluded",
                message: "Can't hear the test tone back — clear the speaker/mic area.",
                severity: .bad))
        }

        // Soft surface: for a known bowl, its resonance should land near the
        // registered tare. A large drop in Q vs. expectation (approximated by low
        // coherence with normal recapture) suggests a damping surface.
        if let bowl = bowl, bowl.tareResonanceHz > 0 {
            let f = output.features["mic_res_f"]
            if f > 0 {
                let drift = abs(f - bowl.tareResonanceHz) / bowl.tareResonanceHz
                if drift > 0.15 {
                    issues.append(SetupIssue(
                        code: "resonance_drift",
                        message: "Bowl resonance shifted a lot from its baseline — soft surface or wrong bowl?",
                        severity: .marginal))
                }
            }
        }

        let quality: SetupQuality
        if issues.contains(where: { $0.severity == .bad }) {
            quality = .bad
        } else if issues.contains(where: { $0.severity == .marginal }) {
            quality = .marginal
        } else {
            quality = .good
        }
        return (quality, issues)
    }
}
