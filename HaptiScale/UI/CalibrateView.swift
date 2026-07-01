//
//  CalibrateView.swift
//  HaptiScale
//
//  Optional per-unit calibration: weigh a known reference mass on a scale, enter it,
//  and HaptiScale ties its features to grams (§6). A few points measurably tighten
//  the calibration-mode estimate. Also shows the device fingerprint.
//

import SwiftUI

struct CalibrateView: View {
    @EnvironmentObject private var coordinator: MeasurementCoordinator
    @State private var knownGrams = ""

    private var profile: DeviceProfile { ProfileStore.shared.profile }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    labeledRow("Model", profile.marketingName)
                    labeledRow("Identifier", profile.hardwareModel)
                    labeledRow("Calibration points", "\(profile.calibrationSamples.count)")
                }

                Section {
                    HStack {
                        TextField("Known weight (g)", text: $knownGrams)
                            .keyboardType(.decimalPad)
                        Button("Add") {
                            if let g = Double(knownGrams) {
                                coordinator.addCalibrationSample(grams: g)
                                knownGrams = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(Double(knownGrams) == nil || coordinator.lastResult == nil)
                    }
                } header: {
                    Text("Add calibration point")
                } footer: {
                    Text("Weigh a known mass in your selected bowl, tap Weigh on the main screen, then enter the true grams here. Two or more points switch the estimator to a fitted curve.")
                }

                if !profile.calibrationSamples.isEmpty {
                    Section("Saved points") {
                        ForEach(profile.calibrationSamples) { s in
                            HStack {
                                Text("\(Int(s.grams)) g").font(.body)
                                Spacer()
                                Text("Δf \(String(format: "%.2f", s.features["d_mic_res_f"])) Hz")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calibrate")
        }
    }

    private func labeledRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}
