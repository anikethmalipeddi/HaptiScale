//
//  BowlRegistry.swift
//  HaptiScale
//
//  Bowl registration + persistence. Each bowl material is effectively a different
//  mechanical filter and should be a registered "bowl class" (§1). Registration runs
//  a tare sweep on the empty bowl and stores its fingerprint; unknown bowls fall back
//  to a generic model with a wider CI. Persisted as JSON alongside the device profile.
//

import Foundation

enum BowlMaterial: String, Codable, CaseIterable, Identifiable {
    case stainless, glass, ceramic, melamine, plastic, other
    var id: String { rawValue }

    /// Relative coupling quality (higher = cleaner, more repeatable resonance).
    /// Drives the estimator's baseline confidence interval width.
    var couplingQuality: Double {
        switch self {
        case .stainless, .glass: return 1.0
        case .ceramic: return 0.75
        case .plastic: return 0.55
        case .melamine: return 0.5
        case .other: return 0.6
        }
    }

    var displayName: String {
        switch self {
        case .stainless: return "Stainless steel"
        case .glass: return "Glass"
        case .ceramic: return "Ceramic"
        case .melamine: return "Melamine"
        case .plastic: return "Plastic"
        case .other: return "Other"
        }
    }
}

struct BowlFingerprint: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var material: BowlMaterial
    /// Empty-bowl tare features captured at registration.
    var tareFeatures: FeatureVector
    var tareResonanceHz: Double
    var created: Date = Date()
}

final class BowlRegistry: ObservableObject {
    static let shared = BowlRegistry()

    @Published private(set) var bowls: [BowlFingerprint] = []
    @Published var selectedBowlID: String?

    private let url: URL

    private init() {
        url = ProfileStore.supportDirectory().appendingPathComponent("bowls.json")
        load()
    }

    var selectedBowl: BowlFingerprint? {
        bowls.first { $0.id == selectedBowlID }
    }

    func register(_ bowl: BowlFingerprint) {
        bowls.append(bowl)
        selectedBowlID = bowl.id
        save()
    }

    func remove(_ id: String) {
        bowls.removeAll { $0.id == id }
        if selectedBowlID == id { selectedBowlID = bowls.first?.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BowlFingerprint].self, from: data) else { return }
        bowls = decoded
        selectedBowlID = decoded.first?.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bowls) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
