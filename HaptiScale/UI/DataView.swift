//
//  DataView.swift
//  HaptiScale
//
//  Training-data collection + signal inspection (§10). Log the last measurement with
//  a ground-truth label (audio WAV + reference WAV + IMU CSV + metadata JSON), see
//  how many records exist and where, and inspect the last measurement's spectra /
//  impulse response for debugging the physics.
//

import SwiftUI

struct DataView: View {
    @EnvironmentObject private var coordinator: MeasurementCoordinator

    @State private var groundTruth = ""
    @State private var surface = "granite"
    @State private var foodClass = ""
    @State private var savedCount = DataLogger.shared.savedCount()

    private let surfaces = ["granite", "hardwood", "board", "tablecloth", "mat", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Collected dataset") {
                    labeledRow("Saved records", "\(savedCount)")
                    labeledRow("Location", "Documents/HaptiScaleData")
                }

                Section {
                    TextField("Ground-truth weight (g)", text: $groundTruth)
                        .keyboardType(.decimalPad)
                    Picker("Surface", selection: $surface) {
                        ForEach(surfaces, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Food class (e.g. rice, apple)", text: $foodClass)
                    Button {
                        coordinator.logLastMeasurement(
                            groundTruthGrams: Double(groundTruth),
                            surface: surface,
                            foodClass: foodClass.isEmpty ? nil : foodClass)
                        savedCount = DataLogger.shared.savedCount()
                    } label: {
                        Label("Log last measurement", systemImage: "square.and.arrow.down")
                    }
                    .disabled(coordinator.lastResult == nil)
                } header: {
                    Text("Log for training")
                } footer: {
                    Text("Records raw audio, the emitted reference, the 100 Hz IMU stream, and all metadata for offline model training.")
                }

                if let out = coordinator.lastExtraction {
                    Section("Last measurement signals") {
                        SpectrumView(magnitudes: out.audioSpectrum, title: "Microphone magnitude spectrum")
                        SpectrumView(magnitudes: out.impulseResponse.map { abs($0) },
                                     title: "Impulse response (matched filter)", logScale: false)
                        VStack(alignment: .leading, spacing: 4) {
                            metric("Mean coherence", String(format: "%.3f", out.meanCoherence))
                            metric("Tilt", String(format: "%.1f°", out.tiltDegrees))
                            metric("Axis asymmetry", String(format: "%.3f", out.axisAsymmetry))
                            metric("Out-of-band energy", String(format: "%.2f", out.nonExcitationEnergyRatio))
                            metric("Recapture level", String(format: "%.2f", out.recaptureLevel))
                            metric("Resonance", String(format: "%.0f Hz", out.features["mic_res_f"]))
                            metric("Q", String(format: "%.1f", out.features["mic_res_q"]))
                            metric("Ring-down τ", String(format: "%.1f ms", out.features["mic_ir_tau"] * 1000))
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("Data")
        }
    }

    private func labeledRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }

    private func metric(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
    }
}
