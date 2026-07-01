//
//  BowlsView.swift
//  HaptiScale
//
//  Register and select bowls. Each bowl material is a distinct mechanical filter, so
//  registration captures an empty-bowl tare fingerprint (§1, §6).
//

import SwiftUI

struct BowlsView: View {
    @EnvironmentObject private var coordinator: MeasurementCoordinator
    @ObservedObject private var registry = BowlRegistry.shared

    @State private var showingRegister = false
    @State private var newName = ""
    @State private var newMaterial: BowlMaterial = .stainless

    var body: some View {
        NavigationStack {
            List {
                Section("Registered bowls") {
                    if registry.bowls.isEmpty {
                        Text("No bowls yet. Register the empty bowl you'll weigh in.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(registry.bowls) { bowl in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bowl.name).font(.body)
                                Text("\(bowl.material.displayName) · resonance \(Int(bowl.tareResonanceHz)) Hz")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if registry.selectedBowlID == bowl.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { registry.selectedBowlID = bowl.id }
                        .swipeActions {
                            Button(role: .destructive) { registry.remove(bowl.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingRegister = true
                    } label: {
                        Label("Register a bowl", systemImage: "plus.circle")
                    }
                    .disabled(coordinator.phase != .ready)
                } footer: {
                    Text("Place the empty bowl on the phone before registering — HaptiScale records its vibration fingerprint.")
                }
            }
            .navigationTitle("Bowls")
            .sheet(isPresented: $showingRegister) { registerSheet }
        }
    }

    private var registerSheet: some View {
        NavigationStack {
            Form {
                Section("Bowl") {
                    TextField("Name (e.g. Steel mixing bowl)", text: $newName)
                    Picker("Material", selection: $newMaterial) {
                        ForEach(BowlMaterial.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                }
                Section {
                    Button {
                        let name = newName.isEmpty ? newMaterial.displayName : newName
                        showingRegister = false
                        Task {
                            await coordinator.registerBowl(name: name, material: newMaterial)
                            newName = ""
                        }
                    } label: {
                        Label("Capture fingerprint", systemImage: "waveform.badge.plus")
                    }
                } footer: {
                    Text("Keep the empty bowl centered and hands off while it records.")
                }
            }
            .navigationTitle("Register bowl")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingRegister = false }
                }
            }
        }
    }
}
