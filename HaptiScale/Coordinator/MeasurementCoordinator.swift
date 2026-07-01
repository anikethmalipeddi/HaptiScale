//
//  MeasurementCoordinator.swift
//  HaptiScale
//
//  The measurement state machine (§9): tare → settle → excite×N → extract → validate
//  → estimate → result. Owns capture, excitation, feature extraction, the estimator
//  and the data logger, and publishes state for SwiftUI. All excitation runs off the
//  main actor; results are published back on the main actor.
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class MeasurementCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case needsMicPermission
        case configuring
        case ready
        case taring
        case settling
        case exciting
        case estimating
        case error(String)
    }

    // Published state for the UI.
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage = "Tap Start to begin."
    @Published private(set) var tareProgress: Double = 0
    @Published private(set) var burstProgress: Double = 0
    @Published private(set) var lastResult: MeasurementResult?
    @Published private(set) var lastExtraction: ExtractionOutput?
    @Published private(set) var hasTare = false
    @Published private(set) var usingTrainedModel = false
    @Published var liveWaveform: [Float] = []

    // Machinery.
    private let audio = AudioCapture()
    private lazy var excitation = ExcitationController(audio: audio)
    private let motion = MotionCapture()
    private let estimator = MassEstimator()
    private var extractor: FeatureExtractor?

    // Session state.
    private var sessionTareBaseline: FeatureVector?
    private var lastBursts: [RawCapture] = []
    private var lastFeatures: FeatureVector?
    private var lastPrediction: MassPrediction?
    private var waveformTimer: Timer?

    let bowls = BowlRegistry.shared

    // MARK: - Lifecycle

    /// Requests permission, configures the audio graph + haptics + motion, and
    /// starts the engine. Idempotent.
    func start() async {
        guard phase == .idle || isErrorPhase else { return }
        phase = .configuring
        statusMessage = "Setting up sensors…"

        let granted = await requestMicPermission()
        guard granted else {
            phase = .needsMicPermission
            statusMessage = "Microphone access is required to weigh."
            return
        }

        do {
            try audio.configure()
            extractor = FeatureExtractor(sampleRate: audio.sampleRate)
            excitation.configure()
            motion.start()
            try audio.start()
            usingTrainedModel = estimator.usingTrainedModel
            registerInterruptionObservers()
            startWaveformUpdates()
            phase = .ready
            statusMessage = hasTare ? "Ready to weigh." : "Place the empty bowl, then Tare."
        } catch {
            phase = .error(error.localizedDescription)
            statusMessage = "Setup failed: \(error.localizedDescription)"
        }
    }

    private var isErrorPhase: Bool { if case .error = phase { return true }; return false }

    // MARK: - Tare

    /// Captures the empty-bowl zero-load baseline (à la VibroScale's 3 s WAIT).
    func captureTare() async {
        guard phase == .ready else { return }
        phase = .taring
        statusMessage = "Taring… keep hands off."
        tareProgress = 0

        let bursts = await runBurstSequence(count: max(3, Config.burstsPerMeasurement),
                                            progress: { [weak self] p in self?.tareProgress = p })
        guard let extractor, !bursts.isEmpty else {
            phase = .ready
            statusMessage = "Tare failed — try again."
            return
        }
        let out = extractor.extract(bursts: bursts)
        sessionTareBaseline = out.features
        hasTare = true
        phase = .ready
        statusMessage = "Tared. Add food, then Weigh."
    }

    // MARK: - Measure

    /// Runs a full measurement and publishes a result.
    func measure() async {
        guard phase == .ready else { return }
        guard let extractor else { return }

        // Prefer the fresh session tare; fall back to the selected bowl's fingerprint.
        let baseline = sessionTareBaseline ?? bowls.selectedBowl?.tareFeatures
        guard let baseline else {
            statusMessage = "Tare first — place the empty bowl and tap Tare."
            return
        }

        phase = .settling
        statusMessage = "Settling…"
        await settle()

        phase = .exciting
        statusMessage = "Weighing…"
        burstProgress = 0
        let bursts = await runBurstSequence(count: Config.burstsPerMeasurement,
                                            progress: { [weak self] p in self?.burstProgress = p })
        guard !bursts.isEmpty else {
            phase = .ready
            statusMessage = "No signal captured — check the setup."
            return
        }

        phase = .estimating
        statusMessage = "Estimating…"

        let out = extractor.extract(bursts: bursts)
        let loadedWithDelta = out.features.withTareDelta(against: baseline)

        let bowl = bowls.selectedBowl
        let (quality, issues) = SetupValidator.evaluate(out, bowl: bowl)
        let prediction = estimator.estimate(features: loadedWithDelta, bowl: bowl)

        let result = MeasurementResult(
            grams: prediction.grams,
            ciLow: prediction.ciLow,
            ciHigh: prediction.ciHigh,
            quality: quality,
            issues: issues,
            coherence: out.meanCoherence,
            features: loadedWithDelta,
            bowlID: bowl?.id,
            env: bursts[0].env)

        lastBursts = bursts
        lastFeatures = loadedWithDelta
        lastPrediction = prediction
        lastExtraction = out
        lastResult = result
        phase = .ready

        switch quality {
        case .good: statusMessage = "Done."
        case .marginal: statusMessage = "Done — accuracy reduced, see warnings."
        case .bad: statusMessage = "Setup problem — fix it and re-weigh."
        }
    }

    // MARK: - Burst sequence

    /// Fires `count` synchronized excitation bursts and returns the per-burst
    /// captures. Each burst: arm → excite → wait (chirp + ring-down) → drain.
    private func runBurstSequence(count: Int, progress: @escaping (Double) -> Void) async -> [RawCapture] {
        var captures: [RawCapture] = []
        let burstWindow = Config.chirpDuration + 0.15   // chirp + ring-down tail
        let env = EnvironmentContext.capture()

        for i in 0..<count {
            audio.armRecording()
            motion.armCollection()

            excitation.fireBurst()
            try? await Task.sleep(nanoseconds: UInt64(burstWindow * 1_000_000_000))

            let recorded = audio.drainRecorded()
            let imu = motion.drain()
            if !recorded.isEmpty {
                captures.append(RawCapture(audio: recorded,
                                           reference: SignalGeneration.standardChirp(sampleRate: audio.sampleRate),
                                           sampleRate: audio.sampleRate,
                                           imu: imu,
                                           env: env,
                                           burstIndex: i))
            }
            progress(Double(i + 1) / Double(count))
            try? await Task.sleep(nanoseconds: UInt64(Config.interBurstGap * 1_000_000_000))
        }
        return captures
    }

    /// Waits until the IMU reports the phone is quiescent (or a timeout).
    private func settle() async {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let tilt = motion.currentTiltDegrees(), tilt < Config.maxTiltDegrees { return }
        }
    }

    // MARK: - Calibration & bowl registration

    /// Records the last measurement's features as a labeled calibration sample.
    func addCalibrationSample(grams: Double) {
        guard let features = lastFeatures else { return }
        let sample = CalibrationSample(grams: grams, features: features,
                                       bowlID: bowls.selectedBowlID, date: Date())
        ProfileStore.shared.update { $0.calibrationSamples.append(sample) }
        statusMessage = "Calibration saved (\(ProfileStore.shared.profile.calibrationSamples.count) points)."
    }

    /// Registers the current empty bowl: captures its tare fingerprint.
    func registerBowl(name: String, material: BowlMaterial) async {
        guard phase == .ready, let extractor else { return }
        phase = .taring
        statusMessage = "Registering \(name)… keep hands off."
        let bursts = await runBurstSequence(count: Config.burstsPerMeasurement,
                                            progress: { [weak self] p in self?.tareProgress = p })
        guard !bursts.isEmpty else { phase = .ready; statusMessage = "Registration failed."; return }
        let out = extractor.extract(bursts: bursts)
        let bowl = BowlFingerprint(name: name, material: material,
                                   tareFeatures: out.features,
                                   tareResonanceHz: out.features["mic_res_f"])
        bowls.register(bowl)
        // A freshly-registered empty bowl is also a valid session tare.
        sessionTareBaseline = out.features
        hasTare = true
        phase = .ready
        statusMessage = "Registered \(name)."
    }

    // MARK: - Data logging

    /// Saves the last measurement to disk with a ground-truth label for training.
    func logLastMeasurement(groundTruthGrams: Double?, surface: String?, foodClass: String?) {
        guard !lastBursts.isEmpty, let features = lastFeatures else { return }
        let bowl = bowls.selectedBowl
        let label = MeasurementLabel(groundTruthGrams: groundTruthGrams,
                                     bowlID: bowl?.id,
                                     bowlMaterial: bowl?.material.rawValue,
                                     surface: surface,
                                     foodClass: foodClass)
        DataLogger.shared.save(bursts: lastBursts, features: features,
                               prediction: lastPrediction, result: lastResult, label: label)
        statusMessage = "Logged (\(DataLogger.shared.savedCount()) records)."
    }

    func resetTare() {
        sessionTareBaseline = nil
        hasTare = false
        statusMessage = "Tare cleared — place the empty bowl and Tare."
    }

    // MARK: - Live waveform

    private func startWaveformUpdates() {
        waveformTimer?.invalidate()
        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.liveWaveform = self.audio.latestSamples(600)
            }
        }
    }

    // MARK: - Interruptions

    private func registerInterruptionObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleInterruption() }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleInterruption() }
        }
    }

    private func handleInterruption() {
        // Any interruption / route change invalidates the tare (blueprint §3).
        resetTare()
        statusMessage = "Audio route changed — re-tare before weighing."
    }

    // MARK: - Permissions

    private func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }
}
