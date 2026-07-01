//
//  MassEstimator.swift
//  HaptiScale
//
//  Maps a tare-delta feature vector to grams + a calibrated confidence interval.
//
//  Two backends:
//   1. CoreMLMassEstimator — loads a trained GBT/NN converted to Core ML if one is
//      bundled ("MassModel.mlmodelc"). Reads point + quantile outputs when present.
//      This is the production path once a dataset exists (§5, §10).
//   2. CalibrationMassEstimator — the ship-from-day-one fallback. Fits grams vs. the
//      most mass-sensitive tare-delta feature from the user's own reference weighings;
//      with no calibration it uses the small-load physics prior Δf/f ≈ −Δm/(2m).
//
//  The wrapper prefers Core ML and falls back automatically, always emitting an
//  honest CI (widened by bowl coupling quality).
//

import Foundation
import CoreML

struct MassPrediction {
    let grams: Double
    let ciLow: Double
    let ciHigh: Double
    let backend: String
}

protocol MassEstimating {
    func estimate(features: FeatureVector, bowl: BowlFingerprint?) -> MassPrediction?
}

/// Top-level estimator: Core ML if available, else calibration/physics.
final class MassEstimator {
    private let coreml = CoreMLMassEstimator()
    private let calibration = CalibrationMassEstimator()

    func estimate(features: FeatureVector, bowl: BowlFingerprint?) -> MassPrediction {
        if let ml = coreml.estimate(features: features, bowl: bowl) { return ml }
        return calibration.estimate(features: features, bowl: bowl)
            ?? MassPrediction(grams: 0, ciLow: 0, ciHigh: 0, backend: "none")
    }

    var usingTrainedModel: Bool { coreml.isLoaded }
}

// MARK: - Core ML backend

final class CoreMLMassEstimator: MassEstimating {
    private var model: MLModel?
    var isLoaded: Bool { model != nil }

    init() {
        // Optional: present only once a model has been trained and added to the app.
        if let url = Bundle.main.url(forResource: "MassModel", withExtension: "mlmodelc") {
            model = try? MLModel(contentsOf: url)
        }
    }

    func estimate(features: FeatureVector, bowl: BowlFingerprint?) -> MassPrediction? {
        guard let model else { return nil }
        // Feed features by name; the trained model must share these names (§4).
        var dict = [String: MLFeatureValue]()
        for (name, value) in features.named { dict[name] = MLFeatureValue(double: value) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
              let out = try? model.prediction(from: provider) else { return nil }

        func read(_ key: String) -> Double? { out.featureValue(for: key)?.doubleValue }
        guard let grams = read("grams") ?? read("target") ?? read("mass") else { return nil }
        let low = read("grams_low") ?? read("q05") ?? grams * 0.9
        let high = read("grams_high") ?? read("q95") ?? grams * 1.1
        return MassPrediction(grams: grams, ciLow: low, ciHigh: high, backend: "coreml")
    }
}

// MARK: - Calibration / physics backend

final class CalibrationMassEstimator: MassEstimating {

    /// Candidate mass-sensitive tare-delta features, most-preferred first.
    private let candidateKeys = ["d_mic_res_f", "d_mic_ir_tau", "d_mic_res_q",
                                 "d_imu_z_tau", "d_mic_band_energy"]

    func estimate(features: FeatureVector, bowl: BowlFingerprint?) -> MassPrediction? {
        let samples = ProfileStore.shared.profile.calibrationSamples
        let coupling = bowl?.material.couplingQuality ?? 0.6

        if samples.count >= 2, let fit = fitBestFeature(samples: samples) {
            let x = features[fit.key]
            let grams = max(0, fit.slope * x + fit.intercept)
            // CI from fit residual std, widened as coupling worsens, with a floor.
            let base = max(fit.residualStd, 6.0)
            let half = base / max(coupling, 0.3)
            return MassPrediction(grams: grams,
                                  ciLow: max(0, grams - half),
                                  ciHigh: grams + half,
                                  backend: "calibration(\(fit.key))")
        }

        // No calibration: small-load physics prior from the resonance shift.
        // Δf/f ≈ −Δm/(2m_eff) ⇒ Δm ≈ −2·m_eff·(Δf/f).
        let df = features["d_mic_res_f"]
        let fLoaded = features["mic_res_f"]
        guard fLoaded > 0, df != 0 else {
            return MassPrediction(grams: 0, ciLow: 0, ciHigh: 0, backend: "uncalibrated")
        }
        let mEff = 300.0                        // rough effective coupled mass (g)
        let grams = max(0, -2.0 * mEff * (df / fLoaded))
        // Physics prior is coarse: very wide CI, honestly flagged.
        let half = max(0.5 * grams, 40.0) / max(coupling, 0.3)
        return MassPrediction(grams: grams,
                              ciLow: max(0, grams - half),
                              ciHigh: grams + half,
                              backend: "physics-prior")
    }

    struct Fit { let key: String; let slope: Double; let intercept: Double; let residualStd: Double; let r2: Double }

    /// Picks the candidate feature with the best linear fit to grams and returns it.
    private func fitBestFeature(samples: [CalibrationSample]) -> Fit? {
        var best: Fit?
        for key in candidateKeys {
            let xs = samples.map { $0.features[key] }
            let ys = samples.map { $0.grams }
            guard let fit = linearFit(xs: xs, ys: ys), fit.slope.isFinite, fit.slope != 0 else { continue }
            let candidate = Fit(key: key, slope: fit.slope, intercept: fit.intercept,
                                residualStd: fit.residualStd, r2: fit.r2)
            if best == nil || candidate.r2 > best!.r2 { best = candidate }
        }
        return best
    }

    private func linearFit(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double, residualStd: Double, r2: Double)? {
        let n = Double(xs.count)
        guard n >= 2 else { return nil }
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in 0..<xs.count {
            sxx += (xs[i] - mx) * (xs[i] - mx)
            sxy += (xs[i] - mx) * (ys[i] - my)
            syy += (ys[i] - my) * (ys[i] - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = my - slope * mx
        var ssRes = 0.0
        for i in 0..<xs.count {
            let pred = slope * xs[i] + intercept
            ssRes += (ys[i] - pred) * (ys[i] - pred)
        }
        let residualStd = sqrt(ssRes / max(1, n - 2))
        let r2 = syy > 0 ? 1 - ssRes / syy : 0
        return (slope, intercept, residualStd, r2)
    }
}
