//
//  RootView.swift
//  HaptiScale
//
//  Tab shell: Weigh, Bowls, Calibrate, Data.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coordinator: MeasurementCoordinator

    var body: some View {
        TabView {
            MeasureView()
                .tabItem { Label("Weigh", systemImage: "scalemass") }
            BowlsView()
                .tabItem { Label("Bowls", systemImage: "circle.dashed") }
            CalibrateView()
                .tabItem { Label("Calibrate", systemImage: "slider.horizontal.3") }
            DataView()
                .tabItem { Label("Data", systemImage: "tray.full") }
        }
        .tint(.green)
        .task {
            if coordinator.phase == .idle { await coordinator.start() }
        }
    }
}
