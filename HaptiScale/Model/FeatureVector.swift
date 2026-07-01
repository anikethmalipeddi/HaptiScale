//
//  FeatureVector.swift
//  HaptiScale
//
//  Named, ordered feature container. Every feature is computed both absolute and —
//  where a tare baseline exists — as a tare-delta (loaded − empty) and ratio, since
//  deltas cancel most device/environment nuisance (§4). The ordered `vector` is what
//  feeds the Core ML / GBT model; `named` is what the DataLogger writes for training.
//

import Foundation

struct FeatureVector: Codable {

    /// Ordered (name, value) pairs. Order is stable and defines the model input.
    private(set) var pairs: [(String, Double)]

    init() { pairs = [] }
    init(_ pairs: [(String, Double)]) { self.pairs = pairs }

    mutating func set(_ name: String, _ value: Double) {
        let v = value.isFinite ? value : 0
        if let idx = pairs.firstIndex(where: { $0.0 == name }) {
            pairs[idx].1 = v
        } else {
            pairs.append((name, v))
        }
    }

    subscript(_ name: String) -> Double {
        pairs.first(where: { $0.0 == name })?.1 ?? 0
    }

    var names: [String] { pairs.map { $0.0 } }
    var vector: [Double] { pairs.map { $0.1 } }
    var named: [String: Double] { Dictionary(uniqueKeysWithValues: pairs) }

    /// Appends tare-delta and ratio features for every key present in both self and
    /// the baseline. Non-destructive: returns a new vector with the extras added.
    func withTareDelta(against baseline: FeatureVector) -> FeatureVector {
        var out = self
        let base = baseline.named
        for (name, value) in pairs {
            guard let b = base[name] else { continue }
            out.set("d_" + name, value - b)
            out.set("r_" + name, b != 0 ? value / b : 0)
        }
        return out
    }

    // MARK: Codable (tuples aren't Codable directly)

    enum CodingKeys: String, CodingKey { case names, values }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = try c.decode([String].self, forKey: .names)
        let values = try c.decode([Double].self, forKey: .values)
        pairs = Array(zip(names, values))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(names, forKey: .names)
        try c.encode(vector, forKey: .values)
    }
}
