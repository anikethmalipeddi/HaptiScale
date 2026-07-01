//
//  AudioCapture.swift
//  HaptiScale
//
//  Owns the shared AVAudioEngine used for both the inaudible chirp playback and the
//  structure-borne microphone capture. Configures the session in `.measurement` mode
//  (disables system AGC/processing — essential for repeatable amplitude), selects the
//  bottom mic (nearest the speaker/Taptic), and taps input into a lock-free ring
//  buffer. Sample rate / IO buffer are read back after activation and treated as the
//  ground truth (iOS honors requests only as hints). See §3.
//

import Foundation
import AVFoundation

final class AudioCapture {

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

    private(set) var sampleRate: Double = Config.preferredSampleRate
    private let ring = RingBuffer(capacity: Int(Config.preferredSampleRate * 4))  // ~4 s
    private(set) var isRunning = false

    /// Host time (seconds) of the first sample captured after `armRecording()`.
    private(set) var captureStartHostTime: TimeInterval = 0

    enum AudioError: Error { case sessionUnavailable(String) }

    // MARK: Session

    /// Configures and activates the audio session, then wires the engine graph.
    func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.mixWithOthers])
        try session.setPreferredSampleRate(Config.preferredSampleRate)
        try session.setPreferredIOBufferDuration(Config.preferredIOBufferDuration)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Force the main (bottom) speaker without engaging voice-processing.
        try? session.overrideOutputAudioPort(.speaker)
        selectBottomMicrophone(session)
        if session.isInputGainSettable { try? session.setInputGain(1.0) }

        // Trust the hardware, not the request.
        sampleRate = session.sampleRate

        buildGraph()
    }

    /// Selects the built-in bottom microphone for the best structure-borne path.
    private func selectBottomMicrophone(_ session: AVAudioSession) {
        guard let inputs = session.availableInputs else { return }
        guard let mic = inputs.first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(mic)
        if let sources = mic.dataSources {
            if let bottom = sources.first(where: { $0.orientation == .bottom }) {
                try? mic.setPreferredDataSource(bottom)
            }
        }
    }

    private func buildGraph() {
        let output = engine.outputNode
        let mainMixer = engine.mainMixerNode

        engine.attach(playerNode)
        // Player → mixer → output, all at the hardware rate.
        let fmt = output.inputFormat(forBus: 0)
        engine.connect(playerNode, to: mainMixer, format: fmt)
        engine.connect(mainMixer, to: output, format: fmt)

        // Prepare the input tap.
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buffer, when in
            self?.handleInput(buffer: buffer, when: when)
        }
    }

    // MARK: Input tap (real-time thread)

    private func handleInput(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        // Record the host time of the very first captured frame after arming.
        if captureStartHostTime == 0, when.isHostTimeValid {
            captureStartHostTime = SyncClock.seconds(fromHostTime: when.hostTime)
        }
        ring.write(channelData[0], count: frames)
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        playerNode.stop()
        engine.stop()
        isRunning = false
    }

    /// Clears buffered audio so the next measurement starts clean.
    func armRecording() {
        ring.reset()
        captureStartHostTime = 0
    }

    /// Drains everything captured so far.
    func drainRecorded() -> [Float] {
        ring.read(max: ring.availableToRead)
    }

    /// Non-destructive snapshot for the live waveform view.
    func latestSamples(_ n: Int) -> [Float] {
        ring.snapshotLatest(count: n)
    }

    /// Schedules the chirp buffer and starts the player immediately.
    func playChirp(_ samples: [Float]) {
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData {
            let channels = Int(fmt.channelCount)
            for c in 0..<channels {
                for i in 0..<samples.count { dst[c][i] = samples[i] }
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
}
