//
//  HaptiScaleApp.swift
//  HaptiScale
//
//  A hybrid active vibro-acoustic food weighing system for iPhone 12–15.
//
//  The app excites the phone chassis with a Taptic (Core Haptics) swept sine and
//  an inaudible speaker FMCW chirp, records the coupled response on the 100 Hz IMU
//  and the 48 kHz microphone, extracts tare-delta spectral / damping / transfer-
//  function features, and maps them to grams. See ARCHITECTURE.md for the full
//  signal chain and the engineering blueprint it implements.
//

import SwiftUI

@main
struct HaptiScaleApp: App {
    /// The single long-lived coordinator that owns capture, excitation and the
    /// measurement state machine. Injected into the environment for all views.
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
