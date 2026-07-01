//
//  MeasureView.swift
//  HaptiScale
//
//  The main weighing screen. Enforces the §7 protocol: flat/hard surface → empty
//  bowl → Tare → add food → Weigh → result + CI + quality badge. Refuses to show a
//  number on a red-quality setup.
//

import SwiftUI

struct MeasureView: View {
    @EnvironmentObject private var coordinator: MeasurementCoordinator

    private var isBusy: Bool {
        switch coordinator.phase {
        case .taring, .settling, .exciting, .estimating, .configuring: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    if coordinator.phase == .needsMicPermission {
                        permissionCard
                    } else if case .error(let msg) = coordinator.phase {
                        errorCard(msg)
                    } else if coordinator.phase == .idle || coordinator.phase == .configuring {
                        startCard
                    } else {
                        controls
                        if isBusy { progressCard }
                        if let result = coordinator.lastResult { ResultCard(result: result) }
                        WaveformView(samples: coordinator.liveWaveform)
                    }
                }
                .padding()
            }
            .navigationTitle("HaptiScale")
            .background(Color.black.ignoresSafeArea())
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text(coordinator.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Label(bowlLabel, systemImage: "circle.dashed").font(.caption)
                if coordinator.usingTrainedModel {
                    Label("Core ML", systemImage: "cpu").font(.caption).foregroundStyle(.green)
                } else {
                    Label("Calibration mode", systemImage: "slider.horizontal.3")
                        .font(.caption).foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var bowlLabel: String {
        coordinator.bowls.selectedBowl?.name ?? "No bowl selected"
    }

    private var startCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "scalemass")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text("Weigh food with vibration")
                .font(.title3.weight(.semibold))
            Text("Lay the phone flat on a hard surface, put a bowl on top, and let HaptiScale feel its weight.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await coordinator.start() }
            } label: {
                Text(coordinator.phase == .configuring ? "Starting…" : "Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.phase == .configuring)
        }
        .padding()
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Task { await coordinator.captureTare() }
                } label: {
                    Label("Tare (empty bowl)", systemImage: "arrow.counterclockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                if coordinator.hasTare {
                    Button(role: .destructive) { coordinator.resetTare() } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button {
                Task { await coordinator.measure() }
            } label: {
                Label("Weigh", systemImage: "scalemass.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || !coordinator.hasTare)

            if !coordinator.hasTare {
                Text("Tare with the empty bowl first.")
                    .font(.caption).foregroundStyle(.yellow)
            }
        }
    }

    private var progressCard: some View {
        VStack(spacing: 8) {
            if coordinator.phase == .taring {
                ProgressView(value: coordinator.tareProgress) { Text("Taring…") }
            } else if coordinator.phase == .exciting {
                ProgressView(value: coordinator.burstProgress) { Text("Weighing…") }
            } else {
                ProgressView().progressViewStyle(.circular)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash").font(.largeTitle).foregroundStyle(.red)
            Text("Microphone access needed")
                .font(.headline)
            Text("HaptiScale plays an inaudible tone and listens to how it changes. Enable microphone access in Settings.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.yellow)
            Text("Something went wrong").font(.headline)
            Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await coordinator.start() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}

import UIKit
